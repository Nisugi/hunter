# frozen_string_literal: true

#
# eohunter's engine, namespace EO::Engine. Loaded by scripts/eohunter.lic:
#
#   load File.join(SCRIPT_DIR, 'eohunter', 'engine.rb')
#
# The control model is Forge's core (Nisugi/forge), nothing game-specific:
#
#   Events    an in-process bus: emit, subscribe, and await with a timeout
#   World     a read-only facade over XMLData / GameObj / Status / Effects / Map
#   Actions   the contract every game command follows: preconditions, settle
#             roundtime, send, await confirmation, return a Result
#   Behavior  a priority and wants_control? / tick over World
#   Engine    the tick loop: the most urgent behavior acts once per tick;
#             watchdog, pause, stop as flags
#
# Every concrete action and behavior (attack, cast, maneuvers, rest, flee,
# target choice) is built on these one at a time from bigshot's rules, with
# the bigshot line references in _WORKSPACES/hunting-engine-plan.md. Combat
# facts come from Lich's Combat::Observers, technique commands and result
# lines from Lich's PSM readers, rather than parsers of our own.
#
# Anchored to the root: Lich evaluates a script body inside Lich::Common.
module ::EO
  module Engine
    VERSION = '0.4.0'.freeze
    HOOK_NAME = 'eohunter::watch'

    # The parts, in dependency order. Each is one file in this directory.
    PARTS = %w[
      events
      world
      targets
      actions
      combat
      maneuvers
      behavior
      rest
      watch
      flee
      wander
      tracking
      loot
      maintain
      survival
      engage
      routines
      travel
      profile
      cleanse
      group
      runner
    ].freeze

    # Load (or reload) every part. +load+ rather than +require+ so an
    # edited part is picked up by the next run of the script.
    def self.load_parts(dir = __dir__)
      PARTS.each { |part| load File.join(dir, "#{part}.rb") }
      true
    end

    def self.version
      VERSION
    end
  end
end

EO::Engine.load_parts
