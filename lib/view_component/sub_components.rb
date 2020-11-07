# frozen_string_literal: true

require "active_support/concern"

require "view_component/slot"

module ViewComponent
  module SubComponents
    extend ActiveSupport::Concern

    # Setup component slot state
    included do
      # Hash of registered Slots
      class_attribute :registered_sub_components
      self.registered_sub_components = {}
    end

    class_methods do
      ##
      # Registers a sub-component
      #
      # = Example
      #
      #   renders_one :header -> (classes:) do
      #     HeaderComponent.new(classes: classes)
      #   end
      #
      #   # OR
      #
      #   renders_on :header, HeaderComponent
      #
      #   where `HeaderComponent` is defined as:
      #
      #   class HeaderComponent < ViewComponent::Base
      #     def initialize(classes:)
      #       @classes = classes
      #     end
      #   end
      #
      #   and has the following template:
      #
      #   <header class="<%= @classes %>">
      #     <%= content %>
      #   </header>
      #
      # = Rendering sub-component content
      #
      # The component's sidecar template can access the sub-component by calling a
      # helper method with the same name as the sub-component.
      #
      #   <h1>
      #     <%= header do %>
      #       My header title
      #     <% end %>
      #   </h1>
      #
      # = Setting sub-component content
      #
      # Consumers of the component can render a sub-component by calling a
      # helper method with the same name as the sub_component.
      #
      #   <%= render_inline(MyComponent.new) do |component| %>
      #     <%= component.header(classes: "Foo") do %>
      #       <p>Bar</p>
      #     <% end %>
      #   <% end %>
      def renders_one(sub_component_name, callable = nil)
        validate_sub_component_name(sub_component_name)

        define_method sub_component_name do |*args, **kwargs, &block|
          if args.empty? && kwargs.empty? && block.nil?
            get_sub_component(sub_component_name)
          else
            set_sub_component(sub_component_name, *args, **kwargs, &block)
          end
        end

        register_slot(sub_component_name, collection: false, callable: callable)
      end

      ##
      # Registers a collection sub-component
      #
      # = Example
      #
      #   render_many :items, -> (name:) { ItemComponent.new(name: name }
      #
      #   # OR 
      #
      #   render_many :items, ItemComponent
      #
      # = Rendering sub-components
      #
      # The component's sidecar template can access the slot by calling a
      # helper method with the same name as the slot.
      #
      #   <h1>
      #     <%= items.each do |item| %>
      #       <%= item %>
      #     <% end %>
      #   </h1>
      #
      # = Setting sub-component content
      #
      # Consumers of the component can set the content of a slot by calling a
      # helper method with the same name as the slot. The method can be
      # called multiple times to append to the slot.
      #
      #   <%= render_inline(MyComponent.new) do |component| %>
      #     <%= component.item(name: "Foo") do %>
      #       <p>One</p>
      #     <% end %>
      #
      #     <%= component.item(name: "Bar") do %>
      #       <p>two</p>
      #     <% end %>
      #   <% end %>
      def renders_many(sub_component_name, callable = nil)
        validate_sub_component_name(sub_component_name)

        singular_name = ActiveSupport::Inflector.singularize(sub_component_name)

        # Define setter for singular names
        # e.g. `renders_many :items` allows fetching all tabs with
        # `component.tabs` and setting a tab with `component.tab`
        define_method singular_name do |*args, **kwargs, &block|
          set_sub_component(sub_component_name, *args, **kwargs, &block)
        end

        # Instantiates and and adds multiple slots forwarding the first
        # argument to each slot constructor
        define_method sub_component_name do |*args, **kwargs, &block|
          if args.empty? && kwargs.empty? && block.nil?
            get_sub_component(sub_component_name)
          end
        end

        register_slot(sub_component_name, collection: true, callable: callable)
      end

      # Clone slot configuration into child class
      # see #test_slots_pollution
      def inherited(child)
        child.registered_sub_components = self.registered_sub_components.clone
        super
      end

      private

      def register_slot(sub_component_name, collection:, callable:)
        # Setup basic slot data
        slot = {
          collection: collection,
        }
        # If callable responds to `render_in`, we set it on the slot as a renderable
        if callable && callable.respond_to?(:method_defined?) && callable.method_defined?(:render_in)
          slot[:renderable] = callable
        elsif callable.is_a?(String)
          # If callable is a string, we assume it's referencing an internal class
          slot[:renderable_class_name] = callable
        elsif callable
          # If slot does not respond to `render_in`, we assume it's a proc,
          # define a method, and save a reference to it to call when setting
          method_name = :"_call_#{sub_component_name}"
          define_method method_name, &callable
          slot[:renderable_function] = instance_method(method_name)
        end

        # Register the slot on the component
        self.registered_sub_components[sub_component_name] = slot
      end

      def validate_sub_component_name(sub_component_name)
        if self.registered_sub_components.key?(sub_component_name)
          # TODO remove? This breaks overriding slots when slots are inherited
          raise ArgumentError.new("#{sub_component_name} slot declared multiple times")
        end
      end
    end

    def get_sub_component(sub_component_name)
      slot = self.class.registered_sub_components[sub_component_name]
      @_set_sub_components ||= {}

      if @_set_sub_components[sub_component_name]
        return @_set_sub_components[sub_component_name]
      end

      if slot[:collection]
        []
      else
        nil
      end
    end

    def set_sub_component(sub_component_name, *args, **kwargs, &block)
      slot = self.class.registered_sub_components[sub_component_name]

      sub_component = SubComponentWrapper.new(self)

      # Passing the block to the sub-component wrapper like this has two
      # benefits:
      #
      # 1. If this is a `content_area` style sub-component, we will render the
      # block via the `sub_component`
      #
      # 2. Since we have to pass block content to components when calling
      # `render`, evaluating the block here would require us to call
      # `view_context.capture` twice, which is slower
      sub_component._content_block = block if block_given?

      # If class
      if slot[:renderable]
        sub_component._component_instance = slot[:renderable].new(*args, **kwargs)
      # If class name as a string
      elsif slot[:renderable_class_name]
        sub_component._component_instance = self.class.const_get(slot[:renderable_class_name]).new(*args, **kwargs)
      # If passed a lambda
      elsif slot[:renderable_function]
        renderable_value = slot[:renderable_function].bind(self).call(*args, **kwargs, &block)

        # Function calls can return components, so if it's a component handle it specially
        if renderable_value.respond_to?(:render_in)
          sub_component._component_instance = renderable_value
        else
          sub_component._content = renderable_value
        end
      end

      @_set_sub_components ||= {}

      if slot[:collection]
        @_set_sub_components[sub_component_name] ||= []
        @_set_sub_components[sub_component_name].push(sub_component)
      else
        @_set_sub_components[sub_component_name] = sub_component
      end

      nil
    end
  end
end
