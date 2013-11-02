require 'puppet/face'
require  'thread'
Puppet::Face.define(:catalog, '0.0.1') do

  action :diff do
    summary "Compare catalogs from different puppet versions."
    arguments "<catalog1> <catalog2>"

    option "--content_diff" do
      summary "Whether to show a diff for File resource content"
    end

    option '--show_resource_diff' do
      summary 'Display differeces between resources in unified diff format'
    end

    option '--exclude_classes' do
      summary 'Do not print classes in resource diffs'
    end

    description <<-'EOT'
      Prints the differences between catalogs compiled by different puppet master to help
      during migrating to a new Puppet version.
    EOT
    notes <<-'NOTES'
      The diff tool recognizes catalogs in yaml, marshall, or pson format.

      Validation Process:

       - Grab a catalog from your existing machine running the old version
       - Configure your new Puppet master, copy the facts from your old master
         to the new one
       - Compile the catalog for this host on the new master:

            puppet master --compile fqdn > fqdn.pson

       - Puppet puts a header in some catalogs compiled in this way, remove it if present
       - At this point you should have 2 different catalogs. To compare them run:

            puppet catalog diff <catalog1> <catalog2>
       - Alternatively you can process a directory containing matching files
       - i.e. path/to/old/node_name.yaml and path/to/new/node_name.yaml
                   puppet catalog diff <path/to/old> <path/to/new>

      Example Output:

      During the transition of 0.24.x to 0.25.x there was a serialization bug
      that resulted in unexpected file content changes, I've recreated this bug
      in a tiny 2 resource catalog, the output below shows how this tool would
      have highlighted this bug prior to upgrading any nodes.

        Resource counts:
          Old: 2
          New: 2

        Catalogs contain the same resources by resource title


        Individual Resource differences:
        Old Resource:
          file{"/tmp/foo":
             content => d3b07384d113edec49eaa6238ad5ff00
          }

        New Resource:
          file{"/tmp/foo":
             content => dbb53f3699703c028483658773628452
          }

      Had resources simply gone missing - not the case here - you would have seen
      a list of that.

      This code only validates the catalogs, it cannot tell you if the behavior of
      the providers that interpret the catalog has changed so testing is still
      recommended, this is just one tool to take away some of the uncertainty

    NOTES
    examples <<-'EOT'
      Compare host catalogs:

      $ puppet catalog diff host-2.6.yaml host-3.0.pson
      $ puppet catalog diff /tmp/old_catalogs /tmp/new_catalogs
    EOT

    when_invoked do |catalog1, catalog2, options|
      require File.expand_path(File.join(File.dirname(__FILE__), "..", "..", "catalog-diff", "differ.rb"))
      require File.expand_path(File.join(File.dirname(__FILE__), "..", "..", "catalog-diff", "findcatalogs.rb"))
      nodes = {}
      if File.directory?(catalog1) && File.directory?(catalog2)
        found_catalogs = Puppet::CatalogDiff::FindCatalogs.new(catalog1,catalog2).return_catalogs(options)
        new_catalogs = found_catalogs.keys
        THREAD_COUNT = 1
        mutex = Mutex.new

        THREAD_COUNT.times.map {
          Thread.new(nodes,new_catalogs,options) do |nodes,new_catalogs,options|
            while new_catalog = mutex.synchronize { new_catalogs.pop }
              node_name    = File.basename(new_catalog,File.extname(new_catalog))
              old_catalog  = found_catalogs[new_catalog]
              node_summary = Puppet::CatalogDiff::Differ.new(old_catalog, new_catalog).diff(options)
              mutex.synchronize { nodes[node_name] = node_summary }
            end
          end
        }.each(&:join)
      else
        node_name = File.basename(catalog2,File.extname(catalog2))
        nodes[node_name] = Puppet::CatalogDiff::Differ.new(catalog1, catalog2).diff(options)
      end
      nodes[:total_percentage] = (nodes.collect{|node,summary| summary[:total_percentage] }.inject{|sum,x| sum + x }.to_i / nodes.size)
      nodes[:total_nodes]      = nodes.size
      nodes
    end
    when_rendering :console do |nodes|
      require File.expand_path(File.join(File.dirname(__FILE__), "..", "..", "catalog-diff", "formater.rb"))
      format = Puppet::CatalogDiff::Formater.new()
      nodes.collect do |node,summary|
            next if node == :total_percentage or node == :total_nodes
            format.node_summary_header(node,summary) + summary.collect do |header,value|
            next if value.nil?
            if value.is_a?(Hash)
              value.collect do |resource_id,resource|
                next if resource.nil?
                if resource.is_a?(Hash) && resource.has_key?(:type)
                  # If we find an actual resource print it out
                  format.resource_reference(header,resource_id,resource)
                elsif resource.is_a?(Array)
                  next unless resource.any?
                  # Format string diffs
                  format.string_diff(header,resource_id,resource)
                else
                  next unless resource.any?
                  # Format hash diffs
                  format.params_diff(header,resource_id,resource)
                end
              end
            elsif value.is_a?(Array)
              next if value.empty?
              # Format arrays
              format.list(header,value)
            else
              format.key_pair(header,value)
            end
          end.delete_if {|x| x.nil? or x == []  }.join("\n")
      end.join("\n") + "#{'-' * 80}\nProcessed #{nodes[:total_nodes]} nodes\nTotal Catalog Changes #{nodes[:total_percentage]}%\n"
    end
  end
end
