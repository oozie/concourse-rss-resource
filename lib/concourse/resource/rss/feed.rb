# frozen_string_literal: true

require 'faraday'
require 'concourse/resource/rss/errors'
require 'rss'
require 'rexml/document'
require 'rexml/xpath'

module Concourse
  module Resource
    module RSS
      class Feed
        Item = Struct.new(:title, :link, :description, :date, :guid) do
          # Keep the RSS field name used by check, in, and the serializer.
          alias_method :pubDate, :date # rubocop:disable Naming/MethodName
        end

        attr_reader :title, :items, :last_build_date, :last_item_date

        def initialize(url)
          response = Faraday.get(url)
          raise FeedUnavailable, "Could not fetch URL #{url}; status is #{response.status}" if response.status != 200

          feed = parse(response.body)
          raise FeedInvalid, url unless feed

          handle(feed, response.body)
        end

        def items_newer_than(version)
          items
            .select { |i| i.pubDate > version }
            .unshift(items_at(version))
            .compact
            .flatten
        end

        def items_at(version)
          items.select { |i| i.pubDate == version }
        end

        private

        def parse(body)
          ::RSS::Parser.parse(body)
        rescue ::RSS::MissingTagError
          # YouTube omits required Atom feed metadata such as updated. Only
          # relax Atom validation; normalization still requires entry dates.
          root = REXML::Document.new(body).root
          raise unless root && root.name == 'feed' && root.namespace == 'http://www.w3.org/2005/Atom'

          ::RSS::Parser.parse(body, false)
        end

        def handle(feed, body)
          if feed.respond_to?(:channel)
            handle_as_rss(feed)
          else
            handle_as_atom(feed, body)
          end
        end

        def handle_as_rss(feed)
          @title = feed.channel.title.chomp
          @last_build_date = feed.channel.lastBuildDate
          @items = feed.items.map { |item| cleanup(item) }
          @last_item_date = @items.first&.pubDate
        end

        def handle_as_atom(feed, body)
          descriptions = media_descriptions(body)
          @title = feed.title.content
          @items = feed.items.map { |entry| atom_item(entry, descriptions) }
          @last_item_date = @items.map(&:pubDate).max
          @last_build_date = feed.updated&.content || @last_item_date
        end

        def atom_item(entry, descriptions)
          date = atom_date(entry)
          link = entry.links.find { |candidate| [nil, 'alternate'].include?(candidate.rel) }
          Item.new(entry.title&.content.to_s, link&.href.to_s, atom_description(entry, descriptions), date, entry.id.content)
        end

        def atom_date(entry)
          date = entry.published&.content || entry.updated&.content
          raise FeedInvalid, 'Atom entry has no published or updated date' unless date

          date
        end

        def atom_description(entry, descriptions)
          (entry.summary&.content || entry.content&.content || descriptions[entry.id.content]).to_s
        end

        def media_descriptions(body)
          namespaces = { 'atom' => 'http://www.w3.org/2005/Atom', 'media' => 'http://search.yahoo.com/mrss/' }
          document = REXML::Document.new(body)
          REXML::XPath.match(document, '/atom:feed/atom:entry', namespaces).to_h do |entry|
            id = REXML::XPath.first(entry, 'atom:id', namespaces)&.text
            description = REXML::XPath.first(entry, 'media:group/media:description', namespaces)&.text
            [id, description]
          end
        end

        def cleanup(item)
          item.tap do |_cleaned|
            item.title.chomp!
            item.link.chomp!
            # item.pubDate already was a parsed Time object
            item.description.chomp! while item.description[-1] == "\n"
            item.guid = item.guid.content
          end
        end
      end
    end
  end
end
