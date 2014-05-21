module Rabl
  class Builder
    class MissingAttribute < RuntimeError; end

    include Rabl::Partials

    SETTING_TYPES = {
      :extends => :file,
      :node    => :name,
      :child   => :data,
      :glue    => :data
    } unless const_defined? :SETTING_TYPES

    # Constructs a new rabl hash based on given object and options
    # options = { :format => "json", :root => true, :child_root => true,
    #   :attributes, :node, :child, :glue, :extends }
    #
    def initialize(options={}, &block)
      filters = (options[:filters] || {}).except!(Filter::CUSTOM.to_s, Filter::DEFAULT.to_s)
      filter_mode = default_filter_mode(filters)
      # some assert
      filters.keys.each { |k| attribute_present?(k) } if filter_mode == Filter::CUSTOM

      @options    = options.reverse_merge(
        filter_mode: filter_mode,
        filters: filters
      )

      @_scope     = options[:scope]
      @_view_path = options[:view_path]
    end

    def default_filter_mode(filters={})
      if filters.empty?
        Filter::DEFAULT
      elsif filters.has_key?(Filter::ALL.to_s)
        filters.except!(Filter::ALL.to_s)
        Filter::ALL
      else
        Filter::CUSTOM
      end
    end

    # Given an object and options, returns the hash representation
    # build(@user, :format => "json", :attributes => { ... }, :root_name => "user")
    def build(object, options={})
      @_object = object

      cache_results do
        compile_hash(options)
      end
    end

    protected

    # Returns a hash representation of the data object
    # compile_hash(:root_name => false)
    # compile_hash(:root_name => "user")
    def compile_hash(options={})
      @_result = {}
      update_settings(:extends)
      update_attributes
      update_settings(:node)
      update_settings(:child)
      update_settings(:glue)

      wrap_result(options[:root_name])

      replace_nil_values          if Rabl.configuration.replace_nil_values_with_empty_strings
      replace_empty_string_values if Rabl.configuration.replace_empty_string_values_with_nil_values
      remove_nil_values           if Rabl.configuration.exclude_nil_values

      # Return Results
      @_root_name ? { @_root_name => @_result } : @_result
    end

    def replace_nil_values
      @_result = @_result.inject({}) do |hash, (k, v)|
        hash[k] = v.nil? ? '' : v
        hash
      end
    end

    def replace_empty_string_values
      @_result = @_result.inject({}) do |hash, (k, v)|
        hash[k] = (!v.nil? && v != "") ? v : nil
        hash
      end
    end

    def remove_nil_values
      @_result = @_result.inject({}) do |hash, (k, v)|
        hash[k] = v unless v.nil?
        hash
      end
    end

    def wrap_result(root_name)
      if root_name.present?
        @_root_name = root_name
      else # no root
        @_root_name = nil
      end
    end

    def update_settings(type)
      settings_type = SETTING_TYPES[type]
      @options[:"allowed_#{type}"].each do |settings|
        send(type, settings[settings_type], settings[:options], &settings[:block])
      end if @options.has_key?(:"allowed_#{type}") && @options[:filter_mode] != Filter::DEFAULT

      @options[type].each do |settings|
        send(type, settings[settings_type], settings[:options], &settings[:block])
      end if @options.has_key?(type)
    end

    def update_attributes
      @options[:allowed_attributes].each_pair do |attribute, settings|
        attribute(attribute, settings)
      end if @options.has_key?(:allowed_attributes) && @options[:filter_mode] != Filter::DEFAULT

      @options[:attributes].each_pair do |attribute, settings|
        attribute(attribute, settings)
      end if @options.has_key?(:attributes)
    end

    # Indicates an attribute or method should be included in the json output
    # attribute :foo, :as => "bar"
    # attribute :foo, :as => "bar", :if => lambda { |m| m.foo }
    def attribute(name, options={})
      if @_object && attribute_present?(name) && resolve_condition(options)
        result_name = (options[:as] || name).to_sym
        if attribute_selected?(result_name) && !@_result.has_key?(result_name)
          attribute = data_object_attribute(name)
          @_result[result_name] = attribute
        end
      end
    end
    alias_method :attributes, :attribute

    # Creates an arbitrary node that is included in the json output
    # node(:foo) { "bar" }
    # node(:foo, :if => lambda { |m| m.foo.present? }) { "bar" }
    def node(name, options={}, &block)
      return unless resolve_condition(options)
      return false unless attribute_selected?(name)
      result = block.call(@_object)
      if name.present?
        @_result[name.to_sym] = result
      elsif result.respond_to?(:each_pair) # merge hash into root hash
        @_result.merge!(result)
      end
    end
    alias_method :code, :node

    # Creates a child node that is included in json output
    # child(@user) { attribute :full_name }
    # child(@user => :person) { ... }
    # child(@users => :people) { ... }
    def child(data, options={}, &block)
      return false unless data.present? && resolve_condition(options)
      name   = is_name_value?(options[:root]) ? options[:root] : data_name(data)
      return false unless attribute_selected?(name)
      result_name = name.to_sym
      return false if @_result.has_key?(result_name)

      object = data_object(data)
      include_root = is_collection?(object) && options.fetch(:object_root, @options[:child_root]) # child @users
      engine_options = @options.slice(:child_root).merge(:root => include_root)
      engine_options.merge!(:object_root_name => options[:object_root]) if is_name_value?(options[:object_root])
      object = { object => name } if data.respond_to?(:each_pair) && object # child :users => :people

      filters = inherited_filters(result_name)
      engine_options.merge!(:filters => filters) if filters

      filter_mode = inherited_filter_mode(result_name)
      engine_options.merge!(:filter_mode => filter_mode) if filter_mode

      @_result[result_name] = self.object_to_hash(object, engine_options, &block)
    end

    def inherited_filters(result_name)
      return unless @options.has_key?(:filters)
      inherited_filters = @options[:filters][result_name.to_s] || {}
      return if inherited_filters.empty?
      inherited_filters
    end

    # inherit only all || custom if inherited_filters present
    def inherited_filter_mode(result_name)
      inherited_filter_mode = @options[:filter_mode]
      if (inherited_filter_mode == Filter::ALL) ||
        (inherited_filter_mode == Filter::CUSTOM && inherited_filters(result_name))
        inherited_filter_mode
      else
        nil
      end
    end

    # Glues data from a child node to the json_output
    # glue(@user) { attribute :full_name => :user_full_name }
    def glue(data, options={}, &block)
      return false unless data.present? && resolve_condition(options)
      return false unless attribute_selected?(data)
      object = data_object(data)
      glued_attributes = self.object_to_hash(object, :root => false, &block)
      @_result.merge!(glued_attributes) if glued_attributes
    end

    # Extends an existing rabl template with additional attributes in the block
    # extends("users/show") { attribute :full_name }
    def extends(file, options={}, &block)
      return unless resolve_condition(options)
      options = @options.slice(:child_root).merge(:object => @_object).merge(options)
      result = self.partial(file, options, &block)
      @_result.merge!(result) if result.is_a?(Hash)
    end

    # Evaluate conditions given a symbol to evaluate
    def call_condition_proc(condition, object, &blk)
      blk = lambda { |v| v } unless block_given?
      if condition.respond_to?(:call)
        # condition is a block to pass to the block
        blk.call(condition.call(object))
      elsif condition.is_a?(Symbol) && object.respond_to?(condition)
        # condition is a property of the object
        blk.call(object.send(condition))
      else
        false
      end
    end

    # resolve_condition(:if => true) => true
    # resolve_condition(:if => lambda { |m| false }) => false
    # resolve_condition(:unless => lambda { |m| true }) => true
    def resolve_condition(options)
      return true if options[:if].nil? && options[:unless].nil?
      result = nil
      if options.has_key?(:if)
        result = options[:if] == true || call_condition_proc(options[:if], @_object)
      end
      if options.has_key?(:unless)
        inverse_proc = lambda { |r| !r }
        result = options[:unless] == false || call_condition_proc(options[:unless], @_object, &inverse_proc)
      end
      result
    end

    private

    # Checks if an attribute is present. If not, check if the configuration specifies that this is an error
    # attribute_present?(created_at) => true
    def attribute_present?(name)
      if @_object.respond_to?(name)
        return true
      elsif Rabl.configuration.raise_on_missing_attribute
        raise MissingAttribute.new("Failed to render missing attribute #{name}")
      else
        return false
      end
    end

    def attribute_selected?(name)
      if @options[:filter_mode] == Filter::CUSTOM
        @options[:filters].include?(name.to_s)
      else
        true
      end
    end

    # Returns a guess at the format in this scope
    # request_format => "xml"
    def request_format
      format = @options[:format]
      format && format != "hash" ? format : 'json'
    end

    # Caches the results of the block based on object cache_key
    # cache_results { compile_hash(options) }
    def cache_results(&block)
      if template_cache_configured? && Rabl.configuration.cache_all_output && @_object.respond_to?(:cache_key)
        result_cache_key = [@_object, @options[:root_name], @options[:format]]
        fetch_result_from_cache(result_cache_key, &block)
      else # skip cache
        yield
      end
    end

  end
end
