require "rubygems"
require "pathname"
require "tempfile"

include_recipe "gearbox::default"
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

    version = new_resource.version
    key = "#{name}/#{version}.tar.gz"
    artifact_dir = ::File::join(node["gearbox"]["app_dir"], name)
    versions_dir = ::File::join(artifact_dir, "versions")
    tar_dir = ::File::join(artifact_dir, "tars")
    tar_file = ::File::join(tar_dir, "#{version}.tar.gz")
    var_dir = ::File::join(artifact_dir, "var")
    log_dir = ::File::join(var_dir, "log")
    data_dir = ::File::join(var_dir, "data")
    run_dir = ::File::join(var_dir, "run")

    [artifact_dir, versions_dir, tar_dir, var_dir, log_dir, data_dir, log_dir].each do |dir|
        directory dir do
            owner name
            group name
            mode "0775"
        end
    end

    unless new_resource.local_path.nil?
        local_path = ::File.join(new_resource.local_path, key)
        execute "cp #{local_path} #{tar_file}"
    else
        unless new_resource.url.nil?
            remote_file tar_file do
                source new_resource.url
            end
        else
            unless new_resource.bucket.nil?
                file tar_file do
                    action :create_if_missing
                    content AWS::S3::S3Object.value key, new_resource.bucket
                    owner name
                    group name
                end
            else
                Chef::Log.warn("I don't know how to get your artifact.")
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
    directory ::File::join(version_dir, 'gbconfig') do
        owner name
        group name
        mode "0755"
    end
    %w{ uwsgi nginx upstart }.each do |dir|
        directory ::File.join(version_dir, 'gbconfig', dir) do 
            owner name
            group name
            mode "0755"
        end

    end
    Mustache::template_path = ::File::join(version_dir, 'gbtemplate')
    databags ||= { } 
    node[:gearbox][:encrypted_data_bags].each do |k,v|
        Chef::Log.info("Decrypting data bags")
        databags[k] = v.map do |args|
            Chef::EncryptedDataBagItem.load(*args).to_hash
        end
    end
    node[:gearbox][:data_bags].each do |k,v|
        databags[k] = v.map do |args|
            data_bag_item(*args).to_hash
        end
    end


    Chef::Log.info("Generating Application Context")

    context = node.to_hash
    context["gearbox"] = {
        "app_home" => artifact_dir,
        "user" => name,
        "group" => name,
        "log_dir" => log_dir,
        "bin_dir" => ::File::join(current_app_dir, 'bin'),
        "config_dir" => ::File::join(current_app_dir, 'gbconfig'),
        "current_app_dir" => current_app_dir,
        "data_dir" => data_dir,
        "run_dir" => run_dir,
        "loaded_data_bags" => databags,
    }
    context[name] = databags

    node.set['gearbox'][name]['templates'] = {}
    ruby_block 'process_template' do
        block do
            ::Dir::glob("#{template_dir}/**/*.mustache").each do |file|
                # skip partials (templates that begin with _)
                next if (::File.basename(file) =~ /^_/)

                template = Pathname.new(file.sub(/\.mustache$/,'')).relative_path_from(template_dir)
                target_file = ::File.join(compiled_dir, template)
                node.set['gearbox'][name]['templates'][target_file] = file
                node.save
            end

        end
        notifies :create, "gearbox_templates[#{name}]"
    end

    # render the templates
    gearbox_templates name do
        action :nothing
        mode "0644"
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
end
