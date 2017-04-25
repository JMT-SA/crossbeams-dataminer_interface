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

      # TODO: Need to see how this should be done when running under passenger/thin/puma...
      # Crossbeams::DataminerInterface::DB = Sequel.postgres(settings.database['name'], user: settings.database['user'], password: settings.database['password'], host: settings.database['host'] || 'localhost')
      Crossbeams::DataminerInterface::DB = Sequel.postgres('kromco', user: 'postgres', password: 'postgres', host: 'localhost')

      def lookup_report(id)
        Crossbeams::DataminerInterface::DmReportLister.new(settings.dm_reports_location).get_report_by_id(id)
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
            hs[:list_values] = query_param.build_list {|sql| Crossbeams::DataminerInterface::DB[sql].all.map {|r| r.values } }.list_values
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
                'I am running this report'
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
