require "rails_helper"

RSpec.describe DataTeller::LLM::HTTP do
  let(:calls) { [] }
  let(:sleeps) { [] }
  let(:url) { "https://provider.test/v1/answer" }

  # Each call takes the next reply, or raises it when it is an exception class.
  def client(*replies, **options)
    transport = lambda do |uri, headers, body|
      calls << { uri: uri, headers: headers, body: body }
      reply = replies.shift
      reply.is_a?(Class) ? raise(reply) : reply
    end
    described_class.new(transport: transport, sleeper: ->(seconds) { sleeps << seconds }, **options)
  end

  def ok(body = { "answer" => 1 }) = described_class::Reply.new(status: 200, body: JSON.generate(body), retry_after: nil)
  def status(code, body = nil, retry_after: nil) = described_class::Reply.new(status: code, body: body && JSON.generate(body), retry_after: retry_after)
  def post(http) = http.post_json(url, headers: { "Authorization" => "Bearer k" }, body: { "q" => "x" })

  it "posts JSON and returns the parsed answer with the latency" do
    data, latency = post(client(ok))

    expect(data).to eq("answer" => 1)
    expect(latency).to be_a(Integer).and(be >= 0)
    expect(calls.first[:uri].to_s).to eq(url)
    expect(calls.first[:headers]).to include("Authorization" => "Bearer k", "Content-Type" => "application/json")
    expect(JSON.parse(calls.first[:body])).to eq("q" => "x")
  end

  it "retries a busy or failing provider, then succeeds" do
    data, = post(client(status(503), status(500), ok))

    expect(data).to eq("answer" => 1)
    expect(calls.size).to eq(3)
    expect(sleeps.size).to eq(2)
    expect(sleeps).to all(be_between(0, described_class::MAX_DELAY))
  end

  it "waits what the provider asks for, within reason" do
    post(client(status(429, retry_after: "2"), ok))

    expect(sleeps).to eq([ 2.0 ])
  end

  it "does not wait for a long Retry-After: a person is waiting" do
    expect { post(client(status(429, { "error" => { "message" => "slow down" } }, retry_after: "60"), ok)) }
      .to raise_error(DataTeller::LLM::RateLimited, /429: slow down/)
    expect(calls.size).to eq(1)
    expect(sleeps).to eq([])
  end

  it "gives up after the retries" do
    expect { post(client(status(429), status(429), status(429), ok)) }.to raise_error(DataTeller::LLM::RateLimited)
    expect(calls.size).to eq(3)

    expect { post(client(status(502), status(502), status(502))) }
      .to raise_error(DataTeller::LLM::ProviderError) { |error| expect(error.status).to eq(502) }
  end

  it "never retries an answer about the request itself" do
    [ 400, 401, 403, 404, 422 ].each do |code|
      calls.clear
      expect { post(client(status(code, { "error" => { "message" => "bad schema" } }), ok)) }
        .to raise_error(DataTeller::LLM::ProviderError, "the provider answered #{code}: bad schema") { |error| expect(error.status).to eq(code) }
      expect(calls.size).to eq(1)
    end
  end

  it "passes the provider's message through the adapter's redaction, cut short" do
    http = client(status(401, { "error" => { "message" => "Incorrect API key provided: sk-abc*****xyz. #{'x' * 400}" } }))

    expect { http.post_json(url, headers: {}, body: {}, redact: ->(text) { text.gsub(/sk-\S+/, "[redacted]") }) }
      .to raise_error(DataTeller::LLM::ProviderError) { |error|
        expect(error.message).to start_with("the provider answered 401: Incorrect API key provided: [redacted]")
        expect(error.message).not_to include("sk-")
        expect(error.message.length).to be < 340
      }
  end

  it "retries a connection that could not be made, then says so" do
    data, = post(client(Errno::ECONNREFUSED, Net::OpenTimeout, ok))
    expect(data).to eq("answer" => 1)

    expect { post(client(SocketError, SocketError, SocketError)) }
      .to raise_error(DataTeller::LLM::ConnectionError, "could not reach the provider (SocketError)")
  end

  it "does not retry a read timeout: the user has already waited" do
    expect { post(client(Net::ReadTimeout, ok, read_timeout: 12)) }
      .to raise_error(DataTeller::LLM::TimeoutError, "the provider did not answer within 12s")
    expect(calls.size).to eq(1)
  end

  it "refuses a success that is not JSON" do
    expect { post(client(described_class::Reply.new(status: 200, body: "<html>", retry_after: nil))) }
      .to raise_error(DataTeller::LLM::InvalidResponse)
  end
end
