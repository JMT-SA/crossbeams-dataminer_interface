module Crossbeams
  module DataminerInterface
    class App < Roda
      include Crossbeams::DataminerInterface::AppHelpers

      use Rack::Session::Cookie, secret: "some_nice_long_random_string_DSKJH4378EYR7EGKUFH", key: "_myapp_session"

      plugin :middleware do |middleware, *args, &block|
        middleware.opts[:dm_config] = args
        block.call(middleware) if block
      end


      plugin :render, views: File.join(File.dirname(__FILE__), 'views')
      plugin :partials
      plugin :public
      plugin :view_subdirs
      plugin :content_for, :append=>true
      plugin :indifferent_params
      plugin :assets, css: 'style.scss'#, js: 'behave.js'
      plugin :json_parser
      plugin :flash


      route do |r|
        r.on 'dataminer' do
          r.root do
            renderer = Crossbeams::Layout::Renderer::Grid.new('rpt_grid', '/dataminer/grid/', 'Report listing', false)
            view(inline: renderer.render)
          end

          r.on 'grid' do
            response['Content-Type'] = 'application/json'
            rpt_list = DmReportLister.new(settings.dm_reports_location).get_report_list(persist: true)
            link     = "'/#{settings.url_prefix}report/'+data.id+'|run'"

            col_defs = [{headerName: '',
                        width: 60,
                        suppressMenu: true,   suppressSorting: true,   suppressMovable: true,
                        suppressFilter: true, enableRowGroup: false,   enablePivot: false,
                        enableValue: false,   suppressCsvExport: true, suppressToolPanel: true,
                        valueGetter: link,
                        colId: "edit_link",
                        cellRenderer: 'crossbeamsGridFormatters.hrefSimpleFormatter' },
                        {headerName: 'Report caption', field: 'caption', width: 300},
                        {headerName: 'File name', field: 'file', width: 600},
                        {headerName: 'Crosstab?', field: 'crosstab',
                         cellRenderer: 'crossbeamsGridFormatters.booleanFormatter',
                         cellClass:    'grid-boolean-column',
                         width:        100}
                       ]
            {
              columnDefs: col_defs,
              rowDefs:    rpt_list.sort_by { |rpt| rpt[:caption] }
            }.to_json
          end

          r.on 'report' do
            r.on :id do |id|
              r.get true do # a GET request that consumes the entire URL (i.e. there is no other part of the ULR after the id)
                @rpt = lookup_report(id)
                @qps = @rpt.query_parameter_definitions
                @rpt_id = id
                @load_params = params[:back] && params[:back] == 'y'
                @crosstab_config = lookup_crosstab(id)

                @report_action = "/#{settings.url_prefix}report/#{id}/run"
                @excel_action = "/#{settings.url_prefix}extract/#{id}/xls"

                view('report/parameters')
              end

              r.post 'run' do
                # puts params.inspect
                # {"limit"=>"", "offset"=>"", "crosstab"=>{"row_columns"=>["organization_code", "commodity_code", "fg_code_old"], "column_columns"=>"grade_code", "value_columns"=>"no_pallets"}, "btnSubmit"=>"Run report", "json_var"=>"[]"}

                @rpt          = lookup_report(id)
                crosstab_hash = lookup_crosstab(id)

                setup_report_with_parameters(@rpt, params, crosstab_hash)

                @col_defs = []
                @rpt.ordered_columns.each do | col|
                  hs                  = {headerName: col.caption, field: col.name, hide: col.hide, headerTooltip: col.caption}
                  hs[:width]          = col.width unless col.width.nil?
                  hs[:enableValue]    = true if [:integer, :number].include?(col.data_type)
                  hs[:enableRowGroup] = true unless hs[:enableValue] && !col.groupable
                  hs[:enablePivot]    = true unless hs[:enableValue] && !col.groupable
                  hs[:rowGroupIndex]  = col.group_by_seq if col.group_by_seq
                  hs[:cellRenderer]   = 'group' if col.group_by_seq
                  hs[:cellRendererParams] = { restrictToOneGroup: true } if col.group_by_seq
                  hs[:aggFunc]        = 'sum' if col.group_sum
                  if [:integer, :number].include?(col.data_type)
                    hs[:cellClass] = 'grid-number-column'
                    hs[:width]     = 100 if col.width.nil? && col.data_type == :integer
                    hs[:width]     = 120 if col.width.nil? && col.data_type == :number
                  end
                  if col.format == :delimited_1000
                    hs[:cellRenderer] = 'crossbeamsGridFormatters.numberWithCommas2'
                  end
                  if col.format == :delimited_1000_4
                    hs[:cellRenderer] = 'crossbeamsGridFormatters.numberWithCommas4'
                  end
                  if col.data_type == :boolean
                    hs[:cellRenderer] = 'crossbeamsGridFormatters.booleanFormatter'
                    hs[:cellClass]    = 'grid-boolean-column'
                    hs[:width]        = 100 if col.width.nil?
                  end

                  # hs[:cellClassRules] = {"grid-row-red": "x === 'Fred'"} if col.name == 'author'

                  @col_defs << hs
                end

                begin
                  # Use module for BigDecimal change? - register_extension...?
                  @row_defs = db_connection[@rpt.runnable_sql].to_a.map {|m| m.keys.each {|k| if m[k].is_a?(BigDecimal) then m[k] = m[k].to_f; end }; m; }

                  @return_action = "/#{settings.url_prefix}report/#{id}"
                  view('report/display')

                rescue Sequel::DatabaseError => e
                  view(inline: <<-EOS)
                  <p style='color:red;'>There is a problem with the SQL definition of this report:</p>
                  <p>Report: <em>#{@rpt.caption}</em></p>The error message is:
                  <pre>#{e.message}</pre>
                  <button class="pure-button" onclick="crossbeamsUtils.toggleVisibility('sql_code', this);return false">
                    <i class="fa fa-info"></i> Toggle SQL
                  </button>
                  <pre id="sql_code" style="display:none;"><%= sql_to_highlight(@rpt.runnable_sql) %></pre>
                  EOS
                end
              end
            end
          end

          r.on 'extract' do
            r.on :id do |id|
              r.post 'xls' do
                @rpt          = lookup_report(id)
                crosstab_hash = lookup_crosstab(id)

                setup_report_with_parameters(@rpt, params, crosstab_hash)

                begin
                  xls_possible_types = {string: :string, integer: :integer, date: :string,
                                        datetime: :time, time: :time, boolean: :boolean, number: :float}
                  heads = []
                  fields = []
                  xls_types = []
                  x_styles = []
                  Axlsx::Package.new do | p |
                    p.workbook do | wb |
                      styles     = wb.styles
                      tbl_header = styles.add_style :b => true, :font_name => 'arial', :alignment => {:horizontal => :center}
                      # red_negative = styles.add_style :num_fmt => 8
                      delim4 = styles.add_style(:format_code=>"#,##0.0000;[Red]-#,##0.0000")
                      delim2 = styles.add_style(:format_code=>"#,##0.00;[Red]-#,##0.00")
                      and_styles = {delimited_1000_4: delim4, delimited_1000: delim2}
                      @rpt.ordered_columns.each do | col|
                        xls_types << xls_possible_types[col.data_type] || :string # BOOLEAN == 0,1 ... need to change this to Y/N...or use format TRUE|FALSE...
                        heads << col.caption
                        fields << col.name
                        # x_styles << (col.format == :delimited_1000_4 ? delim4 : :delimited_1000 ? delim2 : nil) # :num_fmt => Axlsx::NUM_FMT_YYYYMMDDHHMMSS / Axlsx::NUM_FMT_PERCENT
                        x_styles << and_styles[col.format]
                      end
                      puts x_styles.inspect
                      wb.add_worksheet do | sheet |
                        sheet.add_row heads, :style => tbl_header
                        #Crossbeams::DataminerInterface::DB[@rpt.runnable_sql].each do |row|
                        db_connection[@rpt.runnable_sql].each do |row|
                          sheet.add_row(fields.map {|f| v = row[f.to_sym]; v.is_a?(BigDecimal) ? v.to_f : v }, :types => xls_types, :style => x_styles)
                        end
                      end
                    end
                    response.headers['content_type'] = "application/vnd.ms-excel"
                    response.headers['Content-Disposition'] = "attachment; filename=\"#{@rpt.caption.strip.gsub(/[\/:*?"\\<>\|\r\n]/i, '-') + '.xls'}\""
                    response.write(p.to_stream.read) # NOTE: could this streaming to start downloading quicker?
                  end

                rescue Sequel::DatabaseError => e
                  erb(<<-EOS)
                  <p style='color:red;'>There is a problem with the SQL definition of this report:</p>
                  <p>Report: <em>#{@rpt.caption}</em></p>The error message is:
                  <pre>#{e.message}</pre>
                  <button class="pure-button" onclick="crossbeamsUtils.toggleVisibility('sql_code', this);return false">
                    <i class="fa fa-info"></i> Toggle SQL
                  </button>
                  <pre id="sql_code" style="display:none;"><%= sql_to_highlight(@rpt.runnable_sql) %></pre>
                  EOS
                end
              end
            end
          end

          r.on 'admin' do
            r.root do
              @rpt_list = DmReportLister.new(settings.dm_reports_location).get_report_list(from_cache: true)
              @menu     = ''
              view('admin/index')
            # renderer = Renderer::Grid.new('rpt_grid', '/dataminer/admin/grid/', 'Report listing')
            # view(inline: renderer.render)
            end

            r.on 'new' do
              @filename=''
              @caption=''
              @sql=''
              @err=''
              view('admin/new')
            end

            r.on 'create' do # TODO: WHY? can't "r.post 'create'" work?
              r.post do
                s = params[:filename].strip.downcase.tr(' ', '_').gsub(/_+/, '_').gsub(/[\/:*?"\\<>\|\r\n]/i, '-')
                @filename = File.basename(s).reverse.sub(File.extname(s).reverse, '').reverse << '.yml'
                @caption  = params[:caption]
                @sql      = params[:sql]
                @err      = ''

                @rpt = Crossbeams::Dataminer::Report.new(@caption)
                begin
                  @rpt.sql = @sql
                rescue StandardError => e
                  @err = e.message
                end
                # Check for existing file name...
                if File.exists?(File.join(settings.dm_reports_location, @filename))
                  @err = 'A file with this name already exists'
                end
                # Write file, rebuild index and go to edit...

                if @err.empty?
                  # run the report with limit 1 and set up datatypes etc.
                  DmCreator.new(db_connection, @rpt).modify_column_datatypes
                  yp = Crossbeams::Dataminer::YamlPersistor.new(File.join(settings.dm_reports_location, @filename))
                  @rpt.save(yp)
                  DmReportLister.new(settings.dm_reports_location).get_report_list(persist: true) # Kludge to ensure list is rebuilt...

                  view(inline: <<-EOS)
                  <h1>Saved file...got to admin index and edit...</h1>
                  <p>Filename: <em><%= @filename %></em></p>
                  <p>Caption: <em><%= @rpt.caption %></em></p>
                  <p>SQL: <em><%= @rpt.runnable_sql %></em></p>
                  <p>Columns:<br><% @rpt.columns.each do | column| %>
                    <p><%= column %></p>
                  <% end %>
                  </p>
                  EOS
                else
                  view('admin/new')
                end
              end
            end

            r.on 'convert' do # NB: if this is after the on :id block, it isn't found...
              r.post do
                unless params[:file] &&
                       (@tmpfile = params[:file][:tempfile]) &&
                       (@name = params[:file][:filename])
                  r.redirect("/#{settings.url_prefix}admin/") #return "No file selected"
                end
                @yml  = @tmpfile.read # Store tmpfile so it's available for save? ... currently hiding yml in the form...
                @hash = YAML.load(@yml)
                view('admin/convert')
              end
            end

            r.on 'save_conversion' do
              r.post do
                # puts ">>> PARAMS: #{params.inspect}"
                # yml = nil
                # File.open(params[:temp_path], 'r') {|f| yml = f.read }
                yml = params[:yml]
                hash = YAML.load(yml) ### --- could pass the params from the old yml & set them up too....
                hash['query'] = params[:sql]
                rpt = DmConverter.new(settings.dm_reports_location).convert_hash(hash, params[:filename])
                DmReportLister.new(settings.dm_reports_location).get_report_list(persist: true) # Kludge to ensure list is rebuilt...

                view(inline: <<-EOS)
                <h1>Converted</h1>
                <p>New YAML code:</p>
                <pre>#{yml_to_highlight(rpt.to_hash.to_yaml)}</pre>
                EOS
              end
            end

            r.on :id do |id|
              r.on 'edit' do
                @rpt = lookup_report(id)
                @id  = id
                @filename = File.basename(DmReportLister.new(settings.dm_reports_location).get_file_name_by_id(id))

                @col_defs = [{headerName: 'Column Name', field: 'name'},
                             {headerName: 'Sequence', field: 'sequence_no', cellClass: 'grid-number-column'}, # to be changed in group...
                             {headerName: 'Caption', field: 'caption', editable: true},
                             {headerName: 'Namespaced Name', field: 'namespaced_name'},
                             {headerName: 'Data type', field: 'data_type', editable: true, cellEditor: 'select', cellEditorParams: {
                               values: ['string', 'boolean', 'integer', 'number', 'date', 'datetime']
                             }},
                             {headerName: 'Width', field: 'width', cellClass: 'grid-number-column', editable: true, cellEditor: 'NumericCellEditor'}, # editable NUM ONLY...
                             {headerName: 'Format', field: 'format', editable: true, cellEditor: 'select', cellEditorParams: {
                               values: ['', 'delimited_1000', 'delimited_1000_4']
                             }},
                             {headerName: 'Hide?', field: 'hide', cellRenderer: 'crossbeamsGridFormatters.booleanFormatter', cellClass: 'grid-boolean-column', editable: true, cellEditor: 'select', cellEditorParams: {
                               values: [true, false]
                             }},
                             {headerName: 'Can group by?', field: 'groupable', cellRenderer: 'crossbeamsGridFormatters.booleanFormatter', cellClass: 'grid-boolean-column', editable: true, cellEditor: 'select', cellEditorParams: {
                               values: [true, false]
                             }},
                             {headerName: 'Group Seq', field: 'group_by_seq', cellClass: 'grid-number-column', headerTooltip: 'If the grid opens grouped, this is the grouping level', editable: true, cellEditor: 'select', cellEditorParams: {
                               values: [true, false]
                             }},
                             {headerName: 'Sum?', field: 'group_sum', cellRenderer: 'crossbeamsGridFormatters.booleanFormatter', cellClass: 'grid-boolean-column', editable: true, cellEditor: 'select', cellEditorParams: {
                               values: [true, false]
                             }},
                             {headerName: 'Avg?', field: 'group_avg', cellRenderer: 'crossbeamsGridFormatters.booleanFormatter', cellClass: 'grid-boolean-column', editable: true, cellEditor: 'select', cellEditorParams: {
                               values: [true, false]
                             }},
                             {headerName: 'Min?', field: 'group_min', cellRenderer: 'crossbeamsGridFormatters.booleanFormatter', cellClass: 'grid-boolean-column', editable: true, cellEditor: 'select', cellEditorParams: {
                               values: [true, false]
                             }},
                             {headerName: 'Max?', field: 'group_max', cellRenderer: 'crossbeamsGridFormatters.booleanFormatter', cellClass: 'grid-boolean-column', editable: true, cellEditor: 'select', cellEditorParams: {
                               values: [true, false]
                             }}
                ]
                @row_defs = @rpt.ordered_columns.map {|c| c.to_hash }

                @col_defs_params = [
                  {headerName: '', width: 60, suppressMenu: true, suppressSorting: true, suppressMovable: true, suppressFilter: true,
                   enableRowGroup: false, enablePivot: false, enableValue: false, suppressCsvExport: true,
                   valueGetter: "'/#{settings.url_prefix}admin/#{id}/parameter/delete/' + data.column + '|delete|Are you sure?|delete'", colId: 'delete_link', cellRenderer: 'crossbeamsGridFormatters.hrefPromptFormatter'},

                  {headerName: 'Column', field: 'column'},
                  {headerName: 'Caption', field: 'caption'},
                  {headerName: 'Data type', field: 'data_type'},
                  {headerName: 'Control type', field: 'control_type'},
                  {headerName: 'List definition', field: 'list_def'},
                  {headerName: 'UI priority', field: 'ui_priority'},
                  {headerName: 'Default value', field: 'default_value'}#,
                  #{headerName: 'List values', field: 'list_values'}
                ]

                @row_defs_params = []
                @rpt.query_parameter_definitions.each do |query_def|
                  @row_defs_params << query_def.to_hash
                end
                @save_url = "/#{settings.url_prefix}admin/#{id}/save_param_grid_col/"
                view('admin/edit')
              end

              r.on 'save' do
                r.post do
                  # if new name <> old name, make sure new name has .yml, no spaces and lowercase....
                  @rpt = lookup_report(id)

                  filename = DmReportLister.new(settings.dm_reports_location).get_file_name_by_id(id)
                  if File.basename(filename) != params[:filename]
                    puts "new name: #{params[:filename]} for #{File.basename(filename)}"
                  else
                    puts "No change to file name"
                  end
                  @rpt.caption = params[:caption]
                  @rpt.limit = params[:limit].empty? ? nil : params[:limit].to_i
                  @rpt.offset = params[:offset].empty? ? nil : params[:offset].to_i
                  yp = Crossbeams::Dataminer::YamlPersistor.new(filename)
                  @rpt.save(yp)

                  # Need a flash here...
                  flash[:notice] = "Report's header has been changed."
                  r.redirect("/#{settings.url_prefix}admin/#{id}/edit/")
                end
              end

      #TODO:
      #      - Make JS scoped by crossbeams.
      #      - split editors into another JS file
      #      - ditto formatters etc...
              r.on 'save_param_grid_col' do # JSON
                @rpt = lookup_report(id)
                col = @rpt.columns[params[:key_val]]
                attrib = params[:col_name]
                value  = params[:col_val]
                value  = nil if value.strip == ''
                # Should validate - width numeric, range... caption cannot be blank...
                # group_sum, avg etc should act as radio grps... --> Create service class to do validation.
                # FIXME: width cannot be 0...
                if ['format', 'data_type'].include?(attrib) && !value.nil?
                  col.send("#{attrib}=", value.to_sym)
                else
                  value = value.to_i if attrib == 'width' && !value.nil?
                  col.send("#{attrib}=", value)
                end
                puts ">>> ATTR: #{attrib} - #{value} #{value.class}"
                if attrib == 'group_sum' && value == 'true' # NOTE string value of bool...
                  puts 'CHANGING...'
                  col.group_avg = false
                  col.group_min = false
                  col.group_max = false
                  send_changes = true
                else
                  send_changes = false
                end

                if value.nil? && attrib == 'caption' # Cannot be nil...
                  {status: 'error', message: "Caption for #{params[:key_val]} cannot be blank"}.to_json
                else
                  filename = DmReportLister.new(settings.dm_reports_location).get_file_name_by_id(id)
                  yp = Crossbeams::Dataminer::YamlPersistor.new(filename)
                  @rpt.save(yp)
                  if send_changes
                    {status: 'ok', message: "Changed #{attrib} for #{params[:key_val]}",
                     changedFields: {group_avg: false, group_min: false, group_max: false, group_none: 'A TEST'} }.to_json
                  else
                    {status: 'ok', message: "Changed #{attrib} for #{params[:key_val]}"}.to_json
                  end
                end
              end

              r.on 'parameter' do
                r.on 'new' do
                  @rpt = lookup_report(id)
                  @cols = @rpt.ordered_columns.map { |c| c.namespaced_name }.compact
                  @tables = @rpt.tables
                  @id = id
                  view('admin/new_parameter')
                end

                r.on 'create' do
                  r.post do
                    # Validate... also cannot ad dif col exists as param already
                    @rpt = lookup_report(id)

                    col_name = params[:column]
                    if col_name.nil? || col_name.empty?
                      col_name = "#{params[:table]}.#{params[:field]}"
                    end
                    opts = {:control_type => params[:control_type].to_sym,
                            :data_type => params[:data_type].to_sym, caption: params[:caption]}
                    unless params[:list_def].nil? || params[:list_def].empty?
                      if params[:list_def].start_with?('[') # Array
                        opts[:list_def] = eval(params[:list_def]) # TODO: unpack the string into an array... (Job for the gem?)
                      else
                        opts[:list_def] = params[:list_def]
                      end
                    end

                    param = Crossbeams::Dataminer::QueryParameterDefinition.new(col_name, opts)
                    @rpt.add_parameter_definition(param)

                    filename = DmReportLister.new(settings.dm_reports_location).get_file_name_by_id(id)
                    yp = Crossbeams::Dataminer::YamlPersistor.new(filename)
                    @rpt.save(yp)

                    flash[:notice] = "Parameter has been added."
                    r.redirect("/#{settings.url_prefix}admin/#{id}/edit/")
                  end
                end

                r.on 'delete' do
                  r.on :param_id do |param_id|
                    r.post do # TODO: Can we use delete verb?
                      puts ">>> #{id} | #{param_id}..."
                      @rpt = lookup_report(id)
                      puts ">>> #{param_id}"
                      # puts @rpt.query_parameter_definitions.length
                      puts @rpt.query_parameter_definitions.map { |p| p.column }.sort.join('; ')
                      @rpt.query_parameter_definitions.delete_if { |p| p.column == param_id }
                      # puts @rpt.query_parameter_definitions.length
                      filename = DmReportLister.new(settings.dm_reports_location).get_file_name_by_id(id)
                      # puts filename
                      yp = Crossbeams::Dataminer::YamlPersistor.new(filename)
                      @rpt.save(yp)
                      #puts @rpt.query_parameter_definitions.map { |p| p.column }.sort.join('; ')
                      #params.inspect
                      flash[:notice] = "Parameter has been deleted."
                      r.redirect("/#{settings.url_prefix}admin/#{id}/edit/")
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end
