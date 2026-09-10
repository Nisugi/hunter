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

    # Fire budget: [fires, seconds]. A fire is one tick where the behavior
    # actually acted (its result succeeded or failed; a skipped line or a
    # nil is not a fire). More than +fires+ of them inside any +seconds+
    # window trips the engine's watchdog, the way repeated failures do.
    # Sixty in a minute is faster than roundtime allows a real action, so
    # it only catches a behavior looping on successes without the game
    # slowing it (a retarget loop, a re-search, a stance flip). Nil opts
    # out; the trip behaviors (Wander, Rest) do, since a walk can step
    # through rooms faster than that legitimately.
    def fire_budget = [60, 60]

    def wants_control?(_world) = false

    def tick(_world) = nil
  end
end
