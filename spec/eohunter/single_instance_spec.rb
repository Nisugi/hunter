# frozen_string_literal: true

require_relative 'engine_helper'

# engine.rb's load does remove_const on EO::Engine, and Ruby resolves
# constants at call time, so a second instance hands the first one's
# before_dying a different Watch and Events: killing the older instance
# uninstalls the LIVE one's tracker handlers, its DownstreamHook and its
# event bus, and the running hunt goes silently deaf to every combat
# fact, disarm and flee line. The guard has to sit before that load.
RSpec.describe 'the single-instance guard in eohunter.lic' do
  let(:source) { File.read(File.expand_path('../../scripts/eohunter.lic', __dir__)) }

  it 'refuses a second instance before the engine is loaded' do
    guard = source.index('Script.list.select')
    load_line = source.index("load File.join(SCRIPT_DIR, 'eohunter', 'engine.rb')")
    expect(guard).not_to be_nil, 'no single-instance guard in eohunter.lic'
    expect(guard).to be < load_line, 'the guard must run before the engine load, which does remove_const'
  end

  # Lich's Script objects compare by identity, but saying so explicitly is
  # what makes the expression correct rather than incidentally right: a
  # value-equality subtraction removes both instances and finds none.
  it 'excludes itself by identity, not by value' do
    expect(source).to match(/!s\.equal\?\(me\)/)
  end
end
