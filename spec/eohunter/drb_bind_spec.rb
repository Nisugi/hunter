# frozen_string_literal: true

require 'drb/drb'
require 'socket'

# The leader serves its rally Hub over DRb. A nil URI binds every
# interface, which puts an unauthenticated order channel on the network:
# the Hub answers orders with no credential of any kind, and Order carries
# a :command type that runs an arbitrary game command on the follower
# (group.rb 1302). The engine never sends that order - the leader has
# fourteen order types and :command is not among them - so what the bind
# decides is the whole reachable surface, not one handler.
#
# These pin the socket behaviour scripts/eohunter.lic relies on, so a
# change to the URI it passes cannot quietly re-expose the port.
RSpec.describe 'the rally hub bind address' do
  # The exact URI form scripts/eohunter.lic passes to DRb.start_service.
  let(:loopback_uri) { 'druby://127.0.0.1:0' }
  let(:hub) { Class.new { def ping = :pong }.new }

  around do |example|
    example.run
  ensure
    begin
      DRb.stop_service
    rescue StandardError
      nil
    end
  end

  it 'serves the hub to this machine' do
    DRb.start_service(loopback_uri, hub)
    expect(DRb.uri).to start_with('druby://127.0.0.1:')
    expect(DRbObject.new_with_uri(DRb.uri).ping).to eq(:pong)
  end

  it 'does not answer on a routable address' do
    lan = Socket.ip_address_list.find { |a| a.ipv4? && !a.ipv4_loopback? }
    skip 'no routable IPv4 address on this host' if lan.nil?

    DRb.start_service(loopback_uri, hub)
    port = DRb.uri[/:(\d+)\z/, 1].to_i
    expect do
      Socket.tcp(lan.ip_address, port, connect_timeout: 2, &:close)
    end.to raise_error(SystemCallError)
  end
end
