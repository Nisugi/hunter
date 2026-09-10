# frozen_string_literal: true

# ============================================================================
# behavior (from forge behavior.rb)
# ============================================================================

#
# EO::Engine::Behavior - base for arbiter-scheduled behaviors.
#
# Lower priority number = more urgent. Each engine tick, the highest-
# priority behavior whose wants_control?(world) is true gets #tick(world),
# issues at most one verified Action, and returns its Result (or nil).
# Behaviors hold no positional state: intent is re-derived from World.
#
module EO::Engine
  class Behavior
    def priority = 100

    def name = self.class.name.split('::').last.downcase

    def wants_control?(_world) = false

    def tick(_world) = nil
  end
end
