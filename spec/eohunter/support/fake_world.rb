# frozen_string_literal: true

require 'ostruct'

# Minimal mutable World stand-in for behavior/action/engine specs.
class FakeWorld
  FakeNpc = Struct.new(:id, :noun, :name, :status)

  attr_reader :me
  attr_accessor :npcs

  def initialize
    @me = OpenStruct.new(
      dead?: false, muckled?: false, standing?: true,
      in_rt?: false, in_cast_rt?: false, stance_text: 'offensive',
      health_pct: 100, hidden?: false, mana: 100, wounds: {},
      active_spells: []
    )
    @npcs = []
    @sent_commands = []
    @count = 0
    # Me#spell_active?(num) against the active_spells list, so buff
    # maintenance can be exercised without stubbing per example.
    spells = @me.active_spells
    @me.define_singleton_method(:spell_active?) { |num| spells.include?(num.to_i) }
  end

  attr_reader :sent_commands

  def send_command(cmd) = @sent_commands << cmd

  # hands facade (world.hands returns self)
  def holding?(_pattern) = false

  def room = self

  # room identity: uid is the game id, id the lich id, count the
  # did-I-move counter the Move action verifies against
  attr_writer :uid, :id
  attr_accessor :count

  # unmapped = true models standing in a room the mapdb doesn't know:
  # Map.current is nil, so room.id is nil (uid still reports - the GAME
  # knows where we are, the map doesn't).
  attr_accessor :unmapped

  def uid = @uid ||= 1
  def id  = @unmapped ? nil : (@id ||= 1)

  # room title for the survey runner's :room_surveyed event
  attr_writer :title

  def title = @title || 'a fake room'

  def hands = self

  # hazard + exit stubs for the survival specs
  attr_accessor :hazard_nouns, :exits

  def hazards
    Array(@hazard_nouns).map { |n| FakeNpc.new(nil, n, n, nil) }
  end

  def hazardous? = hazards.any?

  def live_creatures
    @npcs.reject { |n| n.status.to_s =~ /dead|gone/ }
  end

  # full room roster + ground items (vine checks, ground-cast verification)
  def creatures = @npcs

  attr_writer :loot

  def loot = @loot ||= []

  # hands facade with settable exist-ids per hand (equipment/loadout
  # specs); held_ids stays independently settable for simpler cases
  FakeHand = Struct.new(:id, :noun, :contents)

  attr_accessor :right_id, :left_id, :right_noun, :left_noun, :right_contents, :left_contents
  attr_writer :held_ids

  def right = FakeHand.new(@right_id, @right_noun || 'item', @right_contents)
  def left  = FakeHand.new(@left_id, @left_noun || 'item', @left_contents)

  def right_empty? = @right_id.nil?
  def left_empty?  = @left_id.nil?
  def empty?       = right_empty? && left_empty?

  def held_ids = @held_ids || [@right_id, @left_id].compact.map(&:to_s)

  def creature_by_id(id)
    @npcs.find { |n| n.id == id.to_s }
  end

  # routing stubs: no map data by default (runner falls back to level order)
  attr_accessor :distances, :uid_map

  # Map#find_nearest stand-in: the nearest of +ids+ that has a priced
  # route from here, or nil when none do. With no distance table at all,
  # fall back to "everything is reachable" so specs that do not care
  # about routing keep working.
  def nearest_reachable(ids)
    ids = Array(ids).map(&:to_i)
    return ids.first if @distances.nil?
    return id if ids.include?(id) # standing in one of them

    ids.select { |i| @distances[i] }.min_by { |i| @distances[i] }
  end

  def uid_ids(uid) = (@uid_map || {}).fetch(uid.to_i, [uid.to_i])

  def room_uid(lich_id)
    (@uid_map || {}).find { |_uid, ids| ids.include?(lich_id.to_i) }&.first
  end

  # local graph: {lich_id => {neighbour_id => way}}
  attr_accessor :graph

  def exits_from(lich_id) = (@graph || {}).fetch(lich_id.to_i, {})
end
