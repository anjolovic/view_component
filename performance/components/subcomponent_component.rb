# frozen_string_literal: true

class SubcomponentComponent < ViewComponent::Base
  include ViewComponent::Slotable::V2

  renders_one :header, -> (**kwargs) { HeaderComponent.new(**kwargs) }
  renders_many :items, -> (**kwargs) { ItemComponent.new(**kwargs) }

  class HeaderComponent < ViewComponent::Base
    attr_reader :classes

    def initialize(classes:)
      @classes = classes
    end
  end

  class ItemComponent < ViewComponent::Base
    attr_reader :classes

    def initialize(classes:)
      @classes = classes
    end
  end

  def initialize(name:)
    @name = name
  end
end