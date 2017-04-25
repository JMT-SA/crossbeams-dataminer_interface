module Crossbeams
  module DataminerInterface
    class App < Roda
      plugin :middleware do |middleware, *args, &block|
        middleware.opts[:dm_config] = args
        block.call(middleware) if block
      end

      def settings
        @settings ||= OpenStruct.new(opts[:dm_config].first)
# dm_js_location, dm_css_location
# dm_js_location: javascripts
# dm_css_location: stylesheets
      end

      def db_connection
        settings.db_connection
      end

      def lookup_report(id)
        Crossbeams::DataminerInterface::DmReportLister.new(settings.dm_reports_location).get_report_by_id(id)
      end

    def clean_where(sql)
      rems = sql.scan( /\{(.+?)\}/).flatten.map {|s| "#{s}={#{s}}" }
      rems.each {|r| sql.gsub!(%r|and\s+#{r}|i,'') }
        rems.each {|r| sql.gsub!(r,'') }
      sql.sub!(/where\s*\(\s+\)/i, '')
      sql
    end

    def sql_to_highlight(sql)
      # wrap sql @ 120
      width = 120
      ar = sql.gsub(/from /i, "\nFROM ").gsub(/where /i, "\nWHERE ").gsub(/(left outer join |left join |inner join |join )/i, "\n\\1").split("\n")
      wrapped_sql = ar.map {|a| a.scan(/\S.{0,#{width-2}}\S(?=\s|$)|\S+/).join("\n") }.join("\n")

      theme = Rouge::Themes::Github.new
      formatter = Rouge::Formatters::HTMLInline.new(theme)
      lexer  = Rouge::Lexers::SQL.new
      formatter.format(lexer.lex(wrapped_sql))
    end

    def yml_to_highlight(yml)
      theme = Rouge::Themes::Github.new
      formatter = Rouge::Formatters::HTMLInline.new(theme)
      lexer  = Rouge::Lexers::YAML.new
      formatter.format(lexer.lex(yml))
    end

    def setup_report_with_parameters(rpt, params)
      #{"col"=>"users.department_id", "op"=>"=", "opText"=>"is", "val"=>"17", "text"=>"Finance", "caption"=>"Department"}
      input_parameters = ::JSON.parse(params[:json_var])
      # logger.info input_parameters.inspect
      parms = []
      # Check if this should become an IN parmeter (list of equal checks for a column.
      eq_sel = input_parameters.select { |p| p['op'] == '=' }.group_by { |p| p['col'] }
      in_sets = {}
      in_keys = []
      eq_sel.each do |col, qp|
        in_keys << col if qp.length > 1
      end

      input_parameters.each do |in_param|
        col = in_param['col']
        if in_keys.include?(col)
          in_sets[col] ||= []
          in_sets[col] << in_param['val']
          next
        end
        param_def = @rpt.parameter_definition(col)
        if 'between' == in_param['op']
          parms << Crossbeams::Dataminer::QueryParameter.new(col, Crossbeams::Dataminer::OperatorValue.new(in_param['op'], [in_param['val'], in_param['val_to']], param_def.data_type))
        else
          parms << Crossbeams::Dataminer::QueryParameter.new(col, Crossbeams::Dataminer::OperatorValue.new(in_param['op'], in_param['val'], param_def.data_type))
        end
      end
      in_sets.each do |col, vals|
        param_def = @rpt.parameter_definition(col)
        parms << Crossbeams::Dataminer::QueryParameter.new(col, Crossbeams::Dataminer::OperatorValue.new('in', vals, param_def.data_type))
      end

      rpt.limit  = params[:limit].to_i  if params[:limit] != ''
      rpt.offset = params[:offset].to_i if params[:offset] != ''
      begin
        rpt.apply_params(parms)
      rescue StandardError => e
        return "ERROR: #{e.message}"
      end
    end

      def make_options(ar)
        ar.map do |a|
          if a.kind_of?(Array)
            "<option value=\"#{a.last}\">#{a.first}</option>"
          else
            "<option value=\"#{a}\">#{a}</option>"
          end
        end.join("\n")
      end

    def select_options(value, opts, with_blank = true)
      ar = []
      ar << "<option value=''></option>" if with_blank
      opts.each do |opt|
        if opt.kind_of? Array
          text, val = opt
        else
          val = opt
          text  = opt
        end
        is_sel = val.to_s == value.to_s
        ar << "<option value='#{val}'#{is_sel ? ' selected' : ''}>#{text}</option>"
      end
      ar.join("\n")
    end

    def make_query_param_json(query_params)
      common_ops = [
        ['is', "="],
        ['is not', "<>"],
        ['greater than', ">"],
        ['less than', "<"],
        ['greater than or equal to', ">="],
        ['less than or equal to', "<="],
        ['is blank', "is_null"],
        ['is NOT blank', "not_null"]
      ]
      text_ops = [
        ['starts with', "starts_with"],
        ['ends with', "ends_with"],
        ['contains', "contains"]
      ]
      date_ops = [
        ['between', "between"]
      ]
      # ar = []
      qp_hash = {}
      query_params.each do |query_param|
        hs = {column: query_param.column, caption: query_param.caption,
              default_value: query_param.default_value, data_type: query_param.data_type,
              control_type: query_param.control_type}
        if query_param.control_type == :list
          hs[:operator] = common_ops
          if query_param.includes_list_options?
            hs[:list_values] = query_param.build_list.list_values
          else
            hs[:list_values] = query_param.build_list {|sql| db_connection[sql].all.map {|r| r.values } }.list_values
          end
        elsif query_param.control_type == :daterange
          hs[:operator] = date_ops + common_ops
        else
          hs[:operator] = common_ops + text_ops
        end
        # ar << hs
        qp_hash[query_param.column] = hs
      end
      # ar.to_json
      qp_hash.to_json
    end

      plugin :render, views: File.join(File.dirname(__FILE__), 'views')
      plugin :public
      plugin :view_subdirs
      plugin :content_for, :append=>true
      plugin :indifferent_params
      plugin :assets, css: 'style.scss'#, js: 'behave.js'


      route do |r|
        r.on 'dataminer' do
          r.root do
            rpt_list = DmReportLister.new(settings.dm_reports_location).get_report_list(persist: true)

            render(inline: <<-EOS)
            <h1>Dataminer Reports</h1>
            <ol><li>#{rpt_list.map { |l| "<a href='/#{settings.url_prefix}report/#{l[:id]}'>#{l[:caption]}</a>" }.join('</li><li>')}</li></ol>
            <p><a href='/#{settings.url_prefix}admin'>Admin index</a></p>
            EOS
          end

          r.on 'report' do
            r.on :id do |id|
              r.get true do # a GET request that consumes the entire URL (i.e. there is no other part of the ULR after the id)
                @rpt = lookup_report(id)
                @qps = @rpt.query_parameter_definitions
                @rpt_id = id
                @load_params = params[:back] && params[:back] == 'y'

                @menu = 'NO MENU' # menu
                @report_action = "/#{settings.url_prefix}report/#{id}/run"
                @excel_action = "/#{settings.url_prefix}extract/#{id}/xls"

                view('report/parameters')
              end

              r.post 'run' do
                @rpt = lookup_report(id)
                setup_report_with_parameters(@rpt, params)

                @col_defs = []
                @rpt.ordered_columns.each do | col|
                  hs                  = {headerName: col.caption, field: col.name, hide: col.hide, headerTooltip: col.caption}
                  hs[:width]          = col.width unless col.width.nil?
                  hs[:enableValue]    = true if [:integer, :number].include?(col.data_type)
                  hs[:enableRowGroup] = true unless hs[:enableValue] && !col.groupable
                  hs[:enablePivot]    = true unless hs[:enableValue] && !col.groupable
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
                  render(inline: <<-EOS)
                  <p style='color:red;'>There is a problem with the SQL definition of this report:</p>
                  <p>Report: <em>#{@rpt.caption}</em></p>The error message is:
                  <pre>#{e.message}</pre>
                  <button class="pure-button" onclick="crossbeamsUtils.toggle_visibility('sql_code', this);return false">
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
                'Here we need to generate an Excel file...'
              end
            end
          end

          r.on 'admin' do
            'Got to admin' # TODO: Load as multiroute
          end
        end
      end
    end
  end
end
