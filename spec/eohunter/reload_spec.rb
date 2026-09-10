# frozen_string_literal: true

require 'open3'
require 'rbconfig'

# A script restart loads engine.rb into a process that already holds
# EO::Engine. The header drops the old module first, so the reload
# defines every constant once: no "already initialized constant" noise
# in Lich's debug log, and no method from a since-edited file left over.
# Run in a child process so the reload cannot disturb this suite's engine.
RSpec.describe 'reloading the engine' do
  let(:helper) { File.expand_path('engine_helper.rb', __dir__) }
  let(:engine) { File.expand_path('../../scripts/eohunter/engine.rb', __dir__) }

  it 'loads twice without constant warnings and with the engine intact' do
    script = <<~RUBY
      require #{helper.inspect}
      load #{engine.inspect}
      load #{engine.inspect}
      print EO::Engine::VERSION, ' ', EO::Engine::Behaviors::Engage.name
    RUBY
    out, err, status = Open3.capture3(RbConfig.ruby, '-w', '-e', script)

    expect(status).to be_success, err
    expect(err).not_to match(/already initialized constant|previous definition of/)
    expect(out).to eq("#{EO::Engine::VERSION} EO::Engine::Behaviors::Engage")
  end
end
