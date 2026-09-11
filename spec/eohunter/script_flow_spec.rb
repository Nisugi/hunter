# frozen_string_literal: true

require 'ripper'
require_relative 'engine_helper'

# The script's top-level flow (argument parsing, the modes, bounty mode, the
# teardown) has no behavioral spec: loading eohunter.lic would launch a hunt.
# What can be checked without running it is that every bare name it calls
# resolves to something - a local it assigns, a method it defines, or a Lich
# global. A bare `bounty` shipped in the bounty banner and raised NameError on
# every `;eohunter bounty` run because nothing here was watching.
RSpec.describe 'eohunter.lic top-level flow' do
  let(:source) { File.read(File.expand_path('../../scripts/eohunter.lic', __dir__)) }
  # Everything from the first statement after the EOHunter module to the end.
  let(:offset) { source.index(/^name = script\.vars\[1\]/) }
  let(:flow)   { source[offset..] }
  let(:first_line) { source[0...offset].lines.size + 1 }

  # Kernel methods and Lich globals the flow may legitimately call bare.
  let(:allowed_bare) { %w[exit script binding sleep] }

  # A "vcall" is Ripper's node for a bare identifier used as a call: no
  # receiver, no arguments, no parentheses - exactly the shape of the `bounty`
  # typo. A name the script assigns as a local parses as :var_ref instead, so
  # only genuinely unresolved names reach here.
  def bare_calls(src)
    found = []
    walk = lambda do |node|
      next unless node.is_a?(Array)

      if node[0] == :vcall && node[1].is_a?(Array) && node[1][0] == :@ident
        found << [node[1][1], node[1][2][0]]
      end
      node.each { |child| walk.call(child) }
    end
    walk.call(Ripper.sexp(src))
    found
  end

  it 'parses' do
    expect(Ripper.sexp(flow)).not_to be_nil
  end

  it 'calls no bare name that is neither a local nor a Lich global' do
    unknown = bare_calls(flow).reject { |name, _| allowed_bare.include?(name) }
    located = unknown.map { |name, line| "#{name} (eohunter.lic:#{line + first_line - 1})" }
    expect(located).to be_empty, "undefined bare names in the top-level flow: #{located.join(', ')}"
  end

  # The banner that raised: it must report through a reader that exists and
  # rescues, not a bare name. world.bounty_text is World's checkbounty seam.
  it 'reports the bounty task through a World reader' do
    banner = flow[/EOHunter\.msg\('info', "bounty mode on profile.*$/]
    expect(banner).to include('world.bounty_text')
    expect(banner).not_to match(/\#\{bounty\}/)
  end
end
