# frozen_string_literal: true

# The guides link each other with plain markdown links (`[Profiles](profiles.md)`,
# `[Routines](docs/guides/routines.md)` from the README) so they read on
# GitHub. YARD copies those hrefs into the generated pages as they are,
# where no `profiles.md` exists: its extra files are `file.profiles.html`.
# This rewrites the hrefs in the generated site to YARD's names, for the
# files YARD was given, and leaves every other link alone.
module EOHunter
  module DocLinks
    # An href to a markdown file, with any docs/ or docs/guides/ prefix and
    # an optional fragment.
    LINK = %r{href="(?:(?:\.\./)*docs/(?:guides/)?)?([\w-]+)\.md(#[^"]*)?"}

    # @param html [String] one generated page
    # @param names [Array<String>] the extra files' basenames without .md
    # @return [String] the page with those hrefs pointing at file.<name>.html
    def self.rewrite(html, names:)
      html.gsub(LINK) do
        name = Regexp.last_match(1)
        fragment = Regexp.last_match(2)
        names.include?(name) ? %(href="file.#{name}.html#{fragment}") : Regexp.last_match(0)
      end
    end

    # The extra files named in .yardopts: every line ending in .md.
    #
    # @param yardopts [String] the path to .yardopts
    # @return [Array<String>] basenames without .md
    def self.names_from(yardopts)
      File.readlines(yardopts, chomp: true).grep(/\.md\z/).map { |line| File.basename(line, '.md') }
    end

    # Rewrite every .html file under +dir+ in place.
    #
    # @param dir [String] the generated site
    # @param names [Array<String>] see {rewrite}
    # @return [Integer] the number of files changed
    def self.rewrite_dir(dir, names:)
      Dir.glob(File.join(dir, '**', '*.html')).count do |path|
        html = File.read(path, encoding: 'utf-8')
        out = rewrite(html, names: names)
        next false if out == html

        File.write(path, out, encoding: 'utf-8')
        true
      end
    end
  end
end
