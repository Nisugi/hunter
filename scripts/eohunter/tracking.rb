# frozen_string_literal: true

# ============================================================================
# tracking (bigshot's bandit hunting and Ranger tracking)
# ============================================================================

#
# Bandits never appear in the room feed, so bigshot hunts them by scraping
# a manual LOOK and manufacturing the quarry with GameObj.new_npc
# (bandit_track 9459), one last look before leaving each room (bs_wander
# 9375). Bandit mode also relaxes the rules that would otherwise stop a
# bandit fight: the target list is the bandit nouns on the quick routine
# (sort_npcs 8622), priority never switches (8675), should_flee? answers
# no past always_flee_from (8540) and the ambusher hook is off (2760).
# It is turned on by ";bigshot bounty" when the bounty says "suppress
# bandit activity" (set_bounty_eval 3824, 3357) and by nothing else.
#
# Rangers TRACK toward a named creature when off cooldown before every
# wander step (ranger_track 9488): a trail moves us and we stay; "You
# don't have to go far" means it is hidden here, so we stay when the room
# is ours and move when it is not; anything else moves on. A room with
# nothing hostile showing gets an UNCOVER (9520): 609 open for a Ranger
# with it, else SEARCH. The creature is the script's free argument
# (";bigshot single giant rat", 3331).
#
# Here: Tracking::Policy from the script's options and the bounty text,
# Actions::BanditLook, Actions::Track, Actions::Uncover, and Wander takes
# the policy. Rules and line references in hunting-engine-plan.md,
# "Bandits and tracking".
#
module EO::Engine
  module Tracking
    # bigshot 3332
    BANDIT_NOUNS = /bandit|brigand|robber|thug|thief|rogue|outlaw|mugger|marauder|highwayman/i
    # set_bounty_eval 3824
    BANDIT_BOUNTY = /suppress bandit activity/

    # +bandits+: hunt bandits; +creature+: the Ranger's quarry, nil for none.
    Policy = Struct.new(:bandits, :creature, keyword_init: true) do
      def initialize(bandits: false, creature: nil) = super

      def bandits? = bandits ? true : false
      def creature_name = creature.to_s.strip
      def tracking? = !creature_name.empty?
    end

    class << self
      # ";eohunter <profile> [bandits] [track <creature>]" plus bigshot's
      # "bandits when the bounty says so" (3357, 3824). +words+ are the
      # script's arguments after the profile.
      #
      # @param words [Array<String>]
      # @param bounty [String, nil] the bounty text, nil to skip the check
      def policy_from(words, bounty: nil)
        words = Array(words).map(&:to_s)
        bandits = words.any? { |w| w =~ /\Abandits?\z/i } || bounty.to_s =~ BANDIT_BOUNTY ? true : false
        creature = nil
        if (i = words.index { |w| w =~ /\Atrack\z/i })
          creature = words[(i + 1)..].join(' ')
        end
        Policy.new(bandits: bandits, creature: creature.to_s.empty? ? nil : creature)
      end

      # sort_npcs 8622-8631 in bandit mode: only the bandit nouns, on the
      # quick routine. Targets::Policy anchors each key.
      def bandit_targets = { "(?:#{BANDIT_NOUNS.source})" => 'quick' }
    end
  end

  module Actions
    # bandit_track (9459): a quiet LOOK, the first bandit noun in it
    # registered with GameObj and put at the head of the game's target
    # ids so Targets can see it.
    class BanditLook < Base
      ANCHOR = %r{<a exist="(.*?)" noun="(.*?)">(.*?)</a>}

      def preconditions = me.dead? ? :dead : :ok

      def perform
        settle_rt
        found = Array(look_lines).flat_map { |l| l.to_s.scan(ANCHOR) }.find { |_id, noun, _name| noun =~ Tracking::BANDIT_NOUNS }
        return Result.new(status: :failed, reason: :no_bandit) if found.nil?

        id, noun, name = found
        name = name.gsub('  ', ' ')
        @world.register_npc(id, noun, name) unless @world.room.targets.any? { |t| t.id.to_s == id.to_s }
        @world.add_current_target(id)
        settle_rt
        Result.new(status: :success, reason: :bandit_found, line: name)
      end

      # The raw LOOK, XML kept: the anchors carry the ids.
      def look_lines = @world.look_lines
    end

    # ranger_track (9488): TRACK <creature>, read as the game answers.
    # :trail (we followed it; success), :here (hidden in this room;
    # success), else failed with the reason.
    class Track < Base
      RESULTS = {
        trail: /Your keen eye spots the beginnings of a trail and you rush to follow it/,
        here: /You don't have to go far\./,
        too_old: /was here, but the trail is clearly too old to be worth following\./,
        no_trace: /While you carefully study the area looking for tracks, you find no trace of what you are looking for\./,
        town: /You don't know how to track creatures within town\./,
        cooldown: /You haven't yet recovered from your previous tracking exploit\./
      }.freeze

      def initialize(world, creature:, **opts)
        super(world, **opts)
        @creature = creature.to_s
      end

      def preconditions
        return :dead if me.dead?
        return :no_creature if @creature.strip.empty?
        return :not_a_ranger unless me.profession.to_s =~ /Ranger/i
        return :cooldown if me.cooldown_active?('Tracking')

        :ok
      end

      def perform
        settle_rt
        result = send_and_match("track #{@creature}", Regexp.union(*RESULTS.values), timeout: 1)
        return result unless result.success?

        kind = RESULTS.find { |_k, rx| result.line =~ rx }&.first
        status = %i[trail here].include?(kind) ? :success : :failed
        Result.new(status: status, reason: kind || :unknown, line: result.line)
      end
    end

    # uncover (9520): reveal what hides here, only when nothing hostile
    # shows. 609 open for a Ranger who can afford it, else SEARCH.
    class Uncover < Base
      def preconditions
        return :dead if me.dead?
        return :creatures_here unless @world.room.targets.empty?

        :ok
      end

      def perform
        settle_rt
        s = @world.spell[609]
        if me.profession.to_s =~ /Ranger/i && s&.known? && s.affordable?
          send_through_ladder('incant 609 open')
          settle_rt
          Result.new(status: :success, reason: :spell_609)
        else
          send_through_ladder('search')
          settle_rt
          Result.new(status: :success, reason: :searched)
        end
      end
    end
  end
end
