module Crossbeams
  module DataminerInterface
    # Helpers for the Roda application.
    module AppHelpers
      # The currently logged-in user. The +user_id+ is picked up from the session.
      #
      # @return [Hash] the user record.
      def current_user
        return {} unless session[:user_id]
        db_connection["SELECT * FROM users WHERE id = #{session[:user_id]}"].to_a.first
        # UserRepo.new(DB.db).users.by_pk(session[:user_id]).one
      end

      # Does the logged-in user have admin permission.
      #
      # @return [Boolean] true if the user can do admin tasks.
      def can_do_admin?
        current_user[:department_name] == 'IT'
      end

      # The settings passed to the app.
      #
      # @return [OpenStruct] the app settings.
      def settings
        @settings ||= OpenStruct.new(opts[:dm_config].first)
        # dm_js_location, dm_css_location
        # dm_js_location: javascripts
        # dm_css_location: stylesheets
      end

      # Database connection.
      #
      # @return [ROM::SQL::Gateway] the database connection.
      def db_connection
        settings.db_connection
      end

      # Get a Report from an id.
      #
      # @param id [String] the report id.
      # @return [Crossbeams::Dataminer::Report] the report.
      def lookup_report(id)
        Crossbeams::DataminerInterface::DmReportLister.new(settings.dm_reports_location).get_report_by_id(id)
      end

      # Get a Report's crosstab configuration from an id.
      #
      # @param id [String] the report id.
      # @return [Hash] the crosstab configuration from the report's YAML definition.
      def lookup_crosstab(id)
        Crossbeams::DataminerInterface::DmReportLister.new(settings.dm_reports_location).get_crosstab_hash_by_id(id)
      end

      # Remove artifacts from old dataminer WHERE clause specifications.
      #
      # @param sql [String] the sql to be cleaned.
      # @return [String] the sql with +paramname={paramname}+ artifacts removed.
      def clean_where(sql)
        rems = sql.scan(/\{(.+?)\}/).flatten.map { |s| "#{s}={#{s}}" }
        rems.each { |r| sql.gsub!(/and\s+#{r}/i, '') }
        rems.each { |r| sql.gsub!(r, '') }
        sql.sub!(/where\s*\(\s+\)/i, '')
        sql
      end

      # Syntax highlighting for SQL using Rouge.
      #
      # @param sql [String] the sql.
      # @return [String] HTML styled for syntax highlighting.
      def sql_to_highlight(sql)
        # wrap sql @ 120
        width = 120
        ar = sql.gsub(/from /i, "\nFROM ").gsub(/where /i, "\nWHERE ").gsub(/(left outer join |left join |inner join |join )/i, "\n\\1").split("\n")
        wrapped_sql = ar.map { |a| a.scan(/\S.{0,#{width - 2}}\S(?=\s|$)|\S+/).join("\n") }.join("\n")

        theme     = Rouge::Themes::Github.new
        formatter = Rouge::Formatters::HTMLInline.new(theme)
        lexer     = Rouge::Lexers::SQL.new
        formatter.format(lexer.lex(wrapped_sql))
      end

      # Syntax highlighting for YAML using Rouge.
      #
      # @param yml [String] the yaml string.
      # @return [String] HTML styled for syntax highlighting.
      def yml_to_highlight(yml)
        theme     = Rouge::Themes::Github.new
        formatter = Rouge::Formatters::HTMLInline.new(theme)
        lexer     = Rouge::Lexers::YAML.new
        formatter.format(lexer.lex(yml))
      end

      # Apply request parameters to a Report.
      #
      # @param rpt [Crossbeams::Dataminer::Report] the report.
      # @param params [Hash] the request parameters.
      # @param crosstab_hash [Hash] the crosstab config (if applicable).
      # @return [Crossbeams::Dataminer::Report] the modified report.
      def setup_report_with_parameters(rpt, params, crosstab_hash = {})
        # puts params[:json_var].inspect
        # {"col"=>"users.department_id", "op"=>"=", "opText"=>"is", "val"=>"17", "text"=>"Finance", "caption"=>"Department"}
        input_parameters = ::JSON.parse(params[:json_var])
        # logger.info input_parameters.inspect
        parms   = []
        # Check if this should become an IN parmeter (list of equal checks for a column.
        eq_sel  = input_parameters.select { |p| p['op'] == '=' }.group_by { |p| p['col'] }
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
          parms << if 'between' == in_param['op']
                     Crossbeams::Dataminer::QueryParameter.new(col, Crossbeams::Dataminer::OperatorValue.new(in_param['op'], [in_param['val'], in_param['val_to']], param_def.data_type))
                   else
                     Crossbeams::Dataminer::QueryParameter.new(col, Crossbeams::Dataminer::OperatorValue.new(in_param['op'], in_param['val'], param_def.data_type))
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

          Crossbeams::DataminerInterface::CrosstabApplier.new(db_connection, rpt, params, crosstab_hash).convert_report if params[:crosstab]
          rpt
          # rescue StandardError => e
          #   return "ERROR: #{e.message}"
        end
      end

      # Make option tags for a select tag.
      #
      # @param items [Array] the option items.
      # @return [String] the HTML +option+ tags.
      def make_options(items)
        items.map do |item|
          if item.is_a?(Array)
            "<option value=\"#{item.last}\">#{item.first}</option>"
          else
            "<option value=\"#{item}\">#{item}</option>"
          end
        end.join("\n")
      end

      # Make option tags for a select tag. Optionally pre-select an item and include a blank line.
      #
      # @param value [String] the selected option.
      # @param opts [Array] the option items.
      # @param with_blank [Boolean] true if the first option tag should be blank.
      # @return [String] the HTML +option+ tags.
      def select_options(value, opts, with_blank = true)
        ar = []
        ar << "<option value=''></option>" if with_blank
        opts.each do |opt|
          if opt.is_a? Array
            text, val = opt
          else
            val  = opt
            text = opt
          end
          is_sel = val.to_s == value.to_s
          ar << "<option value='#{val}'#{is_sel ? ' selected' : ''}>#{text}</option>"
        end
        ar.join("\n")
      end

      # Take a report's query parameter definitions and create a JSON representation of them.
      #
      # @param query_params [Array<Crossbeams::Dataminer::QueryParameterDefinition>] the parameter definitions.
      # @return [JSON] a hash of config for the parameters defined for a report.
      def make_query_param_json(query_params)
        common_ops = [
          ['is', '='],
          ['is not', '<>'],
          ['greater than', '>'],
          ['less than', '<'],
          ['greater than or equal to', '>='],
          ['less than or equal to', '<='],
          ['is blank', 'is_null'],
          ['is NOT blank', 'not_null']
        ]
        text_ops = [
          %w[starts with starts_with],
          %w[ends with ends_with],
          %w[contains contains]
        ]
        date_ops = [
          %w[between between]
        ]
        # ar = []
        qp_hash = {}
        query_params.each do |query_param|
          hs = { column: query_param.column, caption: query_param.caption,
                 default_value: query_param.default_value, data_type: query_param.data_type,
                 control_type: query_param.control_type }
          if query_param.control_type == :list
            hs[:operator] = common_ops
            hs[:list_values] = if query_param.includes_list_options?
                                 query_param.build_list.list_values
                               else
                                 query_param.build_list { |sql| db_connection[sql].all.map(&:values) }.list_values
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

      # The prefix to be used for URLs.
      #
      # @return [String] the URL prefix from settings.
      def the_url_prefix
        settings.url_prefix
      end
    end
  end
end
