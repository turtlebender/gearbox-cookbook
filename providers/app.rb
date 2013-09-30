require "rubygems"
require "pathname"
require "tempfile"
require 'fileutils'

def cleanup_files(dir, count)
  keep_index = (-1 * count) -1
  ::Dir.entries(dir).select { |f|
    f != '.' && f != '..'
  }.map { |f|
    ::File.join(dir, f)
  }.sort_by { |f|
    ::File.mtime f
  }[0..keep_index].each { |f|
    ::FileUtils.rm_rf f
  }
end

action :deploy do

    name = new_resource.name

    user name do
        system true
    end

    group name do
        action :modify
        append true
        members %w{gearbox}.select { |user| node.key? user }
    end

    directory "/home/#{name}" do
      action :create
      owner name
      group name
      recursive true
    end

    group node['uwsgi']['user'] do
      action :modify
      members name
      append true
    end

    version = new_resource.version
    key = "#{name}/#{version}.tar.gz"
    artifact_dir = ::File::join(node['gearbox']['app_dir'], name)
    versions_dir = ::File::join(artifact_dir, 'versions')
    tar_dir = ::File::join(artifact_dir, 'tars')
    tar_file = ::File::join(tar_dir, "#{version}.tar.gz")
    var_dir = ::File::join(artifact_dir, 'var')
    log_dir = ::File::join(node['gearbox']['logpath'], name)
    data_dir = ::File::join(var_dir, 'data')
    run_dir = ::File::join(var_dir, 'run')
    spool_dir = ::File::join(var_dir, 'spool')

    [artifact_dir, versions_dir, tar_dir, var_dir, log_dir, data_dir, log_dir, spool_dir].each do |dir|
        directory dir do
            owner name
            group name
            recursive true
            mode '0775'
        end
    end

    logrotate_app name do
      cookbook "logrotate"
      path ::File.join(log_dir, '*.log')
      options ["missingok", "compress", "delaycompress", "notifempty", "copytruncate"]
      frequency "daily"
      rotate 7
      create "644 #{name} #{name}"
    end

    if node['gearbox']['local_path']
        local_path = ::File.join(node['gearbox']['local_path'], key)
        execute "cp #{local_path} #{tar_file}"
    else
        unless new_resource.url.nil?
            remote_file tar_file do
                source new_resource.url
            end
        else
            unless new_resource.bucket.nil? || node['gearbox']['bucket']
              require 'aws-sdk'
              s3 = AWS::S3.new()

              document = s3.buckets[new_resource.bucket].objects[key]

              ::File.open(tar_file, "w") do |f|
                f.write(document.read)
              end

            else
                Chef::Log.warn('I do not know how to get your artifact.')
            end
        end
    end
    version_dir = ::File::join(versions_dir, version)

    script "untar-#{name}" do
        interpreter "bash"
        user name
        not_if { ::File.directory?(version_dir) }
        code <<-EOH
        mkdir -p "#{version_dir}"
        cd "#{version_dir}"
        tar -xzf "#{tar_file}"
        EOH
    end

    current_app_dir = ::File::join(artifact_dir, 'current')
    template_dir = Pathname.new(::File::join(version_dir, 'gbtemplate'))
    compiled_dir = Pathname.new(::File::join(version_dir, 'gbconfig'))
    Mustache::template_path = ::File::join(version_dir, 'gbtemplate')
    directory ::File::join(version_dir, 'gbconfig') do
        owner name
        group name
        mode '0755'
    end
    %w{ uwsgi nginx upstart }.each do |dir|
        directory ::File.join(version_dir, 'gbconfig', dir) do
            owner name
            group name
            mode '0755'
        end

    end

    gearbox_data_bag = data_bag_item('gearbox', name)

    Chef::Log.info('Generating Application Context')
    # Construct the context for mustache from the node and the
    # app's data bag
    context = node.to_hash
    app_context = context[name] || Hash.new
    app_context = app_context.merge gearbox_data_bag.to_hash
    context[name] = app_context
    breakpoint "merged_gearbox_data_bag"


    # Run and store the search data in the context

    unless Chef::Config[:solo]
      (gearbox_data_bag['searches'] || []).each do |search|
          query = "roles:#{search['role']}"
          if !search.include?("multi_environment") || !search["multi_environment"]
              query = "{0} AND chef_environment:#{node.chef_environment}"
              matching_nodes = search(:node, query)
              results = matching_nodes.map do |result|
                  { search['attribute'] => result[search['attribute']] }
              end
          end
          if search.include?("multiple") || search['multiple']
              context[name][search['name']] = results
          else
              context[name][search['name']] = results.first
          end
      end

      lb_list = Array.new

      if gearbox_data_bag.include?("load_balance")
          lbs = search(:node, "lb_scope:#{gearbox_data_bag["load_balance"]} AND chef_environment:#{node.chef_environment}")
          if lbs.empty?
              lbs = search(:node, "lb_scope:#{gearbox_data_bag["load_balance"]}")
          end
          lb_list = lbs.map do |lb|
              { "socket" => "#{lb.ipaddress}#{lb['uwsgi']['fast_router']['subscription_socket']}"}
          end
      end
    end


    # Load additional data bags
    databags = { }

    Chef::Log.info('Loading additional data bags as specified')
    [ node['gearbox']['encrypted_data_bags'] || [], gearbox_data_bag['encrypted_data_bags'] || [] ].each do |encrypted_data_bag_entry|

        encrypted_data_bag_entry.each do |k,v|
            databags[k] = v.map do |args|
                Chef::EncryptedDataBagItem.load(*args).to_hash
            end
        end
    end

    [ node['gearbox']['data_bags'] || [], gearbox_data_bag['data_bags'] || [] ].each do |data_bag_entry|

        data_bag_entry.each do |k,v|
            databags[k] = v.map do |args|
                data_bag_item(*args).to_hash
            end
        end
    end

    app_context.merge databags
    breakpoint "merged_data_bags"
    begin
        context['gearbox']['loaded_data_bags'] = databags
    rescue
        context['gearbox'] = {'loaded_data_bags' => databags}
    end

    context['gearbox'] = {
        'app_home' => artifact_dir,
        'user' => name,
        'group' => name,
        'log_dir' => log_dir,
        'bin_dir' => ::File::join(current_app_dir, 'bin'),
        'config_dir' => ::File::join(current_app_dir, 'gbconfig'),
        'gbconfig' => ::File::join(current_app_dir, 'gbconfig'),
        'current_app_dir' => current_app_dir,
        'data_dir' => data_dir,
        'run_dir' => run_dir,
        'loaded_data_bags' => databags,
        'load_balancers' => lb_list,
    }

    context = context.merge context['gearbox']

    context[name] = app_context.merge databags
    breakpoint "finished_merging_context"
    node.set['gearbox'][name]['templates'] = {}
    ruby_block 'process_template' do
        block do
            ::Dir::glob("#{template_dir}/**/*.mustache").each do |file|
                # skip partials (templates that begin with _)
                next if (::File.basename(file) =~ /^_/)

                template = Pathname.new(file.sub(/\.mustache$/,'')).relative_path_from(template_dir)
                target_file = ::File.join(compiled_dir, template)
                node.set['gearbox'][name]['templates'][target_file] = file
                if not Chef::Config[:solo]
                    node.save
                end
            end

        end
        notifies :create, "gearbox_templates[#{name}]"
    end

    # render the templates
    gearbox_templates name do
        action :nothing
        mode '0644'
        group name
        owner name
        variables(context)
    end

    link current_app_dir do
        action :delete
    end
    link current_app_dir do
        action :create
        to version_dir
    end

    begin
      # Clean up old versions
      cleanup_files(versions_dir, new_resource.keep_version_count)
      # Clean up old tarballs
      cleanup_files(tar_dir, new_resource.keep_version_count)
    rescue
      Chef::Log.info("Unable to cleanup old versions")
    end
end
