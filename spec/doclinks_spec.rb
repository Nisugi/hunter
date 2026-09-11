# frozen_string_literal: true

require 'tmpdir'

require_relative 'spec_helper'
require_relative '../tools/doclinks'

RSpec.describe EOHunter::DocLinks do
  let(:names) { %w[profiles routines getting-started] }

  it 'points guide links at the generated pages, with the README prefix and a fragment' do
    html = '<a href="profiles.md">P</a> <a href="docs/guides/routines.md#words">R</a> <a href="../docs/getting-started.md">G</a>'
    expect(described_class.rewrite(html, names: names))
      .to eq('<a href="file.profiles.html">P</a> <a href="file.routines.html#words">R</a> <a href="file.getting-started.html">G</a>')
  end

  it 'leaves links to files YARD was not given, and every other link, alone' do
    html = '<a href="docs/other.md">O</a> <a href="https://x.y/profiles.md">X</a> <a href="EO/Engine.html">E</a>'
    expect(described_class.rewrite(html, names: names)).to eq(html)
  end

  it 'reads the extra file names from .yardopts' do
    names = described_class.names_from(File.expand_path('../.yardopts', __dir__))
    expect(names).to include('getting-started', 'profiles', 'routines', 'troubleshooting', 'roadmap')
  end

  it 'rewrites files in place and counts the ones it changed' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'a.html'), '<a href="profiles.md">')
      File.write(File.join(dir, 'b.html'), '<a href="EO.html">')
      expect(described_class.rewrite_dir(dir, names: names)).to eq(1)
      expect(File.read(File.join(dir, 'a.html'))).to eq('<a href="file.profiles.html">')
    end
  end
end
