#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "json"
require "net/http"
require "openssl"
require "time"
require "uri"

API = "https://api.appstoreconnect.apple.com"

KEY_ID = ENV.fetch("APP_STORE_CONNECT_API_KEY_ID")
ISSUER_ID = ENV.fetch("APP_STORE_CONNECT_ISSUER_ID")
PRIVATE_KEY = ENV.fetch("APP_STORE_CONNECT_PRIVATE_KEY").gsub("\\n", "\n")
BUNDLE_ID = ENV.fetch("BUNDLE_ID")
APP_VERSION = ENV.fetch("APP_VERSION", "1.0")
BUILD_NUMBER = ENV.fetch("BUILD_NUMBER", "latest")
WHAT_TO_TEST = ENV.fetch("WHAT_TO_TEST", "Latest Portal build.")
MAX_WAIT_SECONDS = Integer(ENV.fetch("MAX_WAIT_SECONDS", "900"))
POLL_SECONDS = Integer(ENV.fetch("POLL_SECONDS", "30"))

$stdout.sync = true
$stderr.sync = true

def latest_build_number(app_id)
  builds = request(:get, "/v1/builds?filter[app]=#{app_id}&sort=-uploadedDate&limit=1").fetch("data")
  return "" if builds.empty?

  builds.first.fetch("attributes").fetch("version")
end

def b64url(data)
  Base64.urlsafe_encode64(data).delete("=")
end

def int_to_fixed_32_bytes(integer)
  hex = integer.to_s(16)
  hex = "0#{hex}" if hex.length.odd?
  [hex].pack("H*").rjust(32, "\0")
end

def jwt
  header = { alg: "ES256", kid: KEY_ID, typ: "JWT" }
  now = Time.now.to_i
  payload = { iss: ISSUER_ID, iat: now, exp: now + 20 * 60, aud: "appstoreconnect-v1" }
  signing_input = "#{b64url(header.to_json)}.#{b64url(payload.to_json)}"

  key = OpenSSL::PKey::EC.new(PRIVATE_KEY)
  digest = OpenSSL::Digest::SHA256.digest(signing_input)
  der_signature = key.dsa_sign_asn1(digest)
  asn1 = OpenSSL::ASN1.decode(der_signature)
  r, s = asn1.value.map(&:value)
  raw_signature = int_to_fixed_32_bytes(r) + int_to_fixed_32_bytes(s)

  "#{signing_input}.#{b64url(raw_signature)}"
end

def request(method, path, body: nil, allow_conflict: false)
  uri = URI("#{API}#{path}")
  klass = case method
          when :get then Net::HTTP::Get
          when :post then Net::HTTP::Post
          else raise "Unsupported method: #{method}"
          end
  req = klass.new(uri)
  req["Authorization"] = "Bearer #{jwt}"
  req["Content-Type"] = "application/json"
  req.body = JSON.generate(body) if body

  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }
  return nil if res.code == "204"
  return nil if allow_conflict && ["409", "422"].include?(res.code)

  unless res.is_a?(Net::HTTPSuccess)
    warn "#{method.to_s.upcase} #{path} failed: HTTP #{res.code}"
    warn res.body
    exit 1
  end

  res.body && !res.body.empty? ? JSON.parse(res.body) : nil
end

def get_one(path, description)
  data = request(:get, path).fetch("data")
  if data.empty?
    warn "Could not find #{description}"
    exit 1
  end
  data.first
end

encoded_bundle_id = URI.encode_www_form_component(BUNDLE_ID)
app = get_one("/v1/apps?filter[bundleId]=#{encoded_bundle_id}&limit=1", "app with bundle id #{BUNDLE_ID}")
app_id = app.fetch("id")

if ARGV.include?("--print-latest-build")
  puts latest_build_number(app_id)
  exit 0
end

puts "Found app #{app_id} for #{BUNDLE_ID}"

build = nil
started = Time.now
loop do
  path = "/v1/builds?filter[app]=#{app_id}&sort=-uploadedDate&limit=20"
  builds = request(:get, path).fetch("data")
  candidates = builds.map { |candidate| candidate.fetch("attributes").fetch("version") }
  puts "Visible recent build numbers: #{candidates.join(", ")}"
  if BUILD_NUMBER == "latest"
    previous = ENV["PREVIOUS_BUILD_NUMBER"]
    build = builds.first
    if build && previous && build.fetch("attributes").fetch("version") == previous
      build = nil
    end
  else
    build = builds.find { |candidate| candidate.fetch("attributes").fetch("version") == BUILD_NUMBER }
  end

  break if build

  if Time.now - started > MAX_WAIT_SECONDS
    expected = BUILD_NUMBER == "latest" ? "a new latest build" : "build #{BUILD_NUMBER}"
    warn "Timed out waiting for #{expected} to appear in App Store Connect"
    exit 1
  end
  sleep POLL_SECONDS
end

build_id = build.fetch("id")
resolved_build_number = build.fetch("attributes").fetch("version")
state = build.fetch("attributes").fetch("processingState")
puts "Selected build #{APP_VERSION} (#{resolved_build_number}) processingState=#{state}"

localizations = request(:get, "/v1/builds/#{build_id}/betaBuildLocalizations?limit=10").fetch("data")
if localizations.empty?
  request(:post, "/v1/betaBuildLocalizations", body: {
    data: {
      type: "betaBuildLocalizations",
      attributes: { locale: "en-US", whatsNew: WHAT_TO_TEST },
      relationships: { build: { data: { type: "builds", id: build_id } } }
    }
  })
  puts "Added TestFlight 'What to Test' text"
else
  puts "Build already has TestFlight localization"
end

groups = request(:get, "/v1/betaGroups?filter[app]=#{app_id}&limit=200").fetch("data")
if groups.empty?
  warn "No internal TestFlight beta groups found; uploaded build will not appear in testers' TestFlight apps until assigned manually."
  exit 1
end

groups.each do |group|
  group_id = group.fetch("id")
  group_name = group.fetch("attributes").fetch("name")
  request(:post, "/v1/betaGroups/#{group_id}/relationships/builds", allow_conflict: true, body: {
    data: [{ type: "builds", id: build_id }]
  })
  puts "Assigned build #{APP_VERSION} (#{resolved_build_number}) to beta group: #{group_name}"
end

puts "TestFlight distribution complete for #{APP_VERSION} (#{resolved_build_number})"
