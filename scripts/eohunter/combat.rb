# frozen_string_literal: true

# ============================================================================
# combat actions (Attack and Cast, from bigshot's attack path and cast_spell)
# ============================================================================

#
# The first two real actions. Attack confirms on the game's own attack
# initiation line, derived from Lich's combat defs (one catalogue, never a
# copy); Cast wraps Spell#cast the way bigshot's cast_spell does and
# classifies its answer. Rules and bigshot line references in
# hunting-engine-plan.md, "Attack and cast".
#
module EO::Engine
  module Actions
    # ATTACK / FIRE / JAB / PUNCH / KICK / GRAPPLE / HURL / AMBUSH at a
    # creature. bigshot sends these bare through bs_put and lets roundtime
    # pace the next command; the ladder's first non-refusal line IS the
    # confirmation, and here it must be an initiation line the combat defs
    # know, or a refusal we can name.
    #
    #   Attack.new(world, target: creature).call
    #   Attack.new(world, target: creature, verb: 'fire').call
    class Attack < Base
      include CombatRt

      DEFAULT_VERB = 'attack'

      # Second-person initiation lines from lib/gemstone/combat/defs: every
      # def whose pattern starts with "You". Loaded lazily so the library
      # loads without the defs (specs) and picks up new defs for free.
      def self.initiation_regex
        @initiation_regex ||= begin
          defs = ::Lich::Gemstone::Combat::Definitions::Attacks::ALL_ATTACKS
          Regexp.union(defs.flat_map(&:patterns).compact.select { |rx| rx.source.start_with?('You') })
        end
      end

      # Answers that mean no swing went out, and why.
      REFUSALS = {
        referent_missing: /^What were you referring to\?|^I could not find what you were referring to\./,
        weapon_missing: /^(?:Fire|Attack|Ambush|Waylay|Hurl|Jab|Punch|Kick|Grapple) what\?$|^You cannot fire|^You have nothing to throw/,
        out_of_reach: /^You can't reach|is not within reach|too far away/,
        hidden: /^And give yourself away!  Never!$/,
        muckled: /^You are still stunned\.$|^You don't seem to be able to move to do that\.$/,
        hands_full: /^But your hands are full!$/,
        no_target: /^You do not currently have a target\.$/
      }.freeze

      # @param command [String, nil] the exact text to send instead of
      #   "verb #id" (a routine's "attack left leg", which relies on the
      #   game's current target the way bigshot's bare send does)
      def initialize(world, target:, verb: DEFAULT_VERB, timeout: 3, command: nil, **opts)
        super(world, target: target, **opts)
        @target = target
        @verb = verb.to_s
        @timeout = timeout
        @command = command
      end

      def preconditions
        return :dead if me.dead?
        return :muckled if me.muckled?
        return :no_target if @target.nil? || @target.id.to_s.empty?

        :ok
      end

      def command = @command || "#{@verb} ##{@target.id}"

      def perform
        result = send_and_match(command, Regexp.union(self.class.initiation_regex, *REFUSALS.values), timeout: @timeout)
        return result unless result.success?

        reason = REFUSALS.find { |_, rx| result.line =~ rx }&.first
        reason ? Result.new(status: :failed, reason: reason, line: result.line) : result
      end
    end

    # A spell at a creature, or on ourselves, through Spell#cast: it owns
    # prepare, release, the cast-stance dance and hindrance retries the
    # same way it does for every script, and bigshot's cast_spell only
    # classifies what it returns. The send therefore does not go through
    # Base's ladder; Spell#cast has its own.
    #
    #   Cast.new(world, spell: 1030, target: creature).call
    #   Cast.new(world, spell: 506).call                       # self
    #   Cast.new(world, spell: 1030, target: creature, extra: 'evoke').call
    class Cast < Base
      include CombatRt

      MAX_HINDRANCE_RETRIES = 3 # bigshot cast_spell max_attempts

      BLOCKED   = /^Be at peace my child, there is no need for spells of war in here\.$|Spells of War cannot be cast/
      NO_TARGET = /^Cast at what\?$|^You do not currently have a target\.$|leaving you casting at nothing but thin air!$/
      HINDERED  = /^\[Spell Hindrance for/
      FIZZLED   = /^Your magic fizzles ineffectually\.$/
      CANNOT_PREPARE = /^You can't think clearly enough to prepare a spell!$|^You are too injured to make that dextrous of a movement|^You can't make that dextrous of a move!$|^The searing pain in your throat makes that impossible|^All you manage to do is cough up some blood\.$|^You do not know that spell!$|^That is not something you can prepare\./
      NO_MANA   = /^But you don't have any mana!$/
      CAST      = /^(?:Cast|Sing) Roundtime [0-9]+ Seconds?\.$|^Roundtime: \d+ sec\.$/

      def initialize(world, spell:, target: nil, extra: nil, incant: false, force_stance: nil, **opts)
        # A creature target participates in the hostile roster liveness
        # check. A named player does not: GameObj.targets never contains
        # allies, so treating the name as an NPC id rejects every support
        # cast before Spell#cast can issue it.
        super(world, target: target.respond_to?(:id) ? target : nil, **opts)
        @spell_number = spell.to_i
        @target = target
        @extra = extra
        @incant = incant
        @force_stance = force_stance
      end

      def preconditions
        return :dead if me.dead?
        return :muckled if me.muckled?

        s = spell
        return :unknown_spell if s.nil? || !s.known?
        return :unaffordable unless s.affordable?

        :ok
      end

      def perform
        attempts = 0
        loop do
          answer = cast_once
          return Result.new(status: :failed, reason: :cast_refused) if answer == false || answer.nil?

          line = answer.to_s
          return Result.new(status: :failed, reason: :blocked, line: line) if line =~ BLOCKED
          return Result.new(status: :failed, reason: :no_target, line: line) if line =~ NO_TARGET
          return Result.new(status: :failed, reason: :cannot_prepare, line: line) if line =~ CANNOT_PREPARE
          return Result.new(status: :failed, reason: :no_mana, line: line) if line =~ NO_MANA
          return Result.new(status: :failed, reason: :fizzled, line: line) if line =~ FIZZLED

          if line =~ HINDERED
            attempts += 1
            return Result.new(status: :failed, reason: :hindrance, line: line) if attempts >= MAX_HINDRANCE_RETRIES
            return Result.new(status: :failed, reason: :interrupted) if interrupted?

            next
          end

          return Result.new(status: :success, line: line)
        end
      end

      private

      def spell
        ::Spell[@spell_number]
      rescue StandardError
        nil
      end

      # bigshot cast_spell (4830): target given -> cast / force_cast /
      # force_channel / force_evoke by the extra word; no target and incant
      # -> force_incant; otherwise a plain cast.
      def cast_once
        s = spell
        if @incant
          # cmd_spell 4922-4936: an incant is sent as INCANT even when a
          # target is in hand; the game's own target takes it
          s.force_incant(@extra, force_stance: @force_stance)
        elsif @target
          target = @target.respond_to?(:id) ? "##{@target.id}" : @target.to_s
          case @extra
          when /cast/    then s.force_cast(target, @extra.gsub('cast', '').strip, force_stance: @force_stance)
          when /channel/ then s.force_channel(target, @extra.gsub('channel', '').strip, force_stance: @force_stance)
          when /evoke/   then s.force_evoke(target, @extra.gsub('evoke', '').strip, force_stance: @force_stance)
          else s.cast(target, nil, @extra, force_stance: @force_stance)
          end
        else
          s.cast(nil, nil, @extra, force_stance: @force_stance)
        end
      end
    end
  end
end
