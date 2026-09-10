# frozen_string_literal: true

# Loads scripts/eohunter/engine.rb (and its parts) outside Lich, once per
# rspec process.
require 'rspec'

# The parts name Script and Lich::Messaging; neither is exercised by these
# specs, but the constants must resolve.
module Lich
  module Messaging
    def self.msg(_kind, _text); end unless respond_to?(:msg)
  end
end

class Script
  def self.current; end unless respond_to?(:current)
end

load File.expand_path('../../scripts/eohunter/engine.rb', __dir__) unless defined?(EO::Engine::Engine)
