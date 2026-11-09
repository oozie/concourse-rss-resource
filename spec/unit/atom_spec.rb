# frozen_string_literal: true

require 'concourse/resource/rss/feed'
require 'concourse/resource/rss/check'
require 'concourse/resource/rss/in'

RSpec.describe 'Atom feed support' do
  let(:url) { 'https://www.youtube.com/feeds/videos.xml?channel_id=UCaJBwb7XkojUOPbz_6uzPag' }
  let(:source) { { 'url' => url } }
  let(:body) { fixture('feed/youtube.atom') }
  let(:content_type) { 'application/atom+xml' }
  let(:feed) { Concourse::Resource::RSS::Feed.new(url) }
  let(:check) { Concourse::Resource::RSS::Check.new }
  let(:latest_date) { Time.parse('2026-11-09T18:00:00+00:00') }

  before do
    stub_request(:get, url).to_return(body: body, headers: { 'Content-Type' => content_type })
  end

  it 'accepts YouTube feeds without a feed-level updated element' do
    expect(feed.title).to eq('EWTN News')
    expect(feed.last_build_date).to eq(latest_date)
    expect(check.call(source, nil)).to eq([{ 'pubDate' => latest_date }])
  end

  it 'returns current and newer versions in chronological order' do
    older_date = Time.parse('2026-11-08T18:00:00+00:00')
    expect(check.call(source, { 'pubDate' => older_date.to_s })).to eq([
                                                                         { 'pubDate' => older_date }, { 'pubDate' => latest_date }
                                                                       ])
    expect(check.call(source, { 'pubDate' => latest_date.to_s })).to eq([{ 'pubDate' => latest_date }])
  end

  it 'fetches a checked version with video metadata and all output files' do
    version = check.call(source, nil).first.transform_values(&:to_s)
    Dir.mktmpdir do |directory|
      output = Concourse::Resource::RSS::In.new(directory).call(source, version)
      expect(output['version']).to eq('pubDate' => latest_date)
      expect(output['metadata']).to include('name' => 'description', 'value' => "Today's news & analysis.")
      expected = {
        'title' => 'Latest news & analysis',
        'link' => 'https://www.youtube.com/watch?v=new-video',
        'description' => "Today's news & analysis.",
        'pubDate' => '2026-11-09T18:00:00+00:00',
        'guid' => 'yt:video:new-video'
      }
      expected.each { |name, value| expect(File.read(File.join(directory, name))).to eq(value) }
    end
  end

  [nil, 'text/xml', 'application/atom+xml; charset=UTF-8', 'application/rss+xml'].each do |header|
    context "with Content-Type #{header.inspect}" do
      let(:content_type) { header }

      it 'detects Atom from the parsed feed' do
        expect(feed.items.first.pubDate).to eq(latest_date)
      end
    end
  end

  context 'with an empty YouTube feed' do
    let(:body) { super().sub(%r{  <entry>.*</entry>}m, '') }

    it 'returns no versions' do
      expect(check.call(source, nil)).to eq([])
      expect(feed.last_build_date).to be_nil
    end
  end

  context 'with an entry missing both dates' do
    let(:body) { super().gsub(%r{    <(?:published|updated)>.*?</(?:published|updated)>\n}, '') }

    it 'rejects an entry that cannot be versioned' do
      expect { feed }.to raise_error(Concourse::Resource::RSS::FeedInvalid)
    end
  end

  context 'with only published entry dates' do
    let(:body) { super().gsub(%r{    <updated>.*?</updated>\n}, '') }

    it 'uses publication dates for versions' do
      expect(check.call(source, nil)).to eq([{ 'pubDate' => latest_date }])
    end
  end

  context 'with Atom summary text' do
    let(:body) { super().sub('    <media:group>', '    <summary>News summary</summary><media:group>') }

    it 'prefers the summary to the Media RSS description' do
      expect(feed.items.first.description).to eq('News summary')
    end
  end

  context 'without entry descriptions' do
    let(:body) { super().gsub(%r{<media:description>.*?</media:description>}, '') }

    it 'provides an empty description for serialization' do
      expect(feed.items.first.description).to eq('')
    end
  end

  context 'with malformed XML' do
    let(:body) { '<feed' }

    it 'still rejects malformed feeds' do
      expect { feed }.to raise_error(StandardError)
    end
  end

  context 'with a GitHub Atom feed using updated dates and HTML content' do
    let(:body) { fixture('feed/releases.atom') }

    it 'normalizes entries for checking and fetching' do
      item = feed.items.first
      expect(item.pubDate).to eq(Time.parse('2018-10-17T00:39:34+02:00'))
      expect(item.description).to eq('<p>Release v2.2.0</p>')
      expect(item.link).to eq('https://github.com/hashicorp/vagrant/releases/tag/v2.2.0')
      expect(check.call(source, { 'pubDate' => item.pubDate.to_s })).to eq([{ 'pubDate' => item.pubDate }])
      Dir.mktmpdir do |directory|
        expect(Concourse::Resource::RSS::In.new(directory).call(source, { 'pubDate' => item.pubDate.to_s })['version'])
          .to eq('pubDate' => item.pubDate)
      end
    end
  end
end
