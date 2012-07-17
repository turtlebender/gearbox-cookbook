#
# Cookbook Name:: gearbox
# Recipe:: default
#
# Copyright 1999-2012 University of Chicago
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
# http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# 

# Get the databags associated with the specific apps

include_recipe "gearbox::deps"

require "aws/s3"

apps = node[:gearbox][:apps].map do |appname|
  data_bag_item("gearbox", appname) 
end

# Compile a list of artifacts
aws_creds = Chef::EncryptedDataBagItem.load("aws_credentials", "boto")
AWS::S3::Base.establish_connection!(
  :access_key_id     => aws_creds["aws_access_key_id"],
  :secret_access_key => aws_creds["aws_secret_access_key"]
) 


artifacts = apps.collect do |bag|
  version = node[:gearbox][:versions][bag['project_name']] || node.chef_environment
  prefix = "#{bag['project_name']}/#{version}"
  bucket = AWS::S3::Bucket.objects(node[:gearbox][:artifact_bucket], :prefix => prefix).sort_by(&:key).last
  raise RuntimeError.new("Failed to find artifact for #{bag["project_name"]}.") if bucket.nil?
  { :bag => bag, :bucket => bucket }
end.reject(&:nil?)

user node[:gearbox][:user] do
  system true
end

directory node[:gearbox][:log_dir] do
  owner node[:gearbox][:user]
  group node[:nginx][:user]
  mode '0775'
end

# load the databags
# TODO: there may be a cleaner way to do this using lambdas
databags ||= { } 
node[:gearbox][:encrypted_data_bags].each do |k,v|
  databags[k] = v.map do |args|
    Chef::EncryptedDataBagItem.load(*args).to_hash
  end
end
node[:gearbox][:data_bags].each do |k,v|
  databags[k] = v.map do |args|
    data_bag_item(*args).to_hash
  end
end

# Install each artifact

artifacts.each do |artifact|
  artifact_name = File::basename(artifact[:bucket].key)
  artifact_dir = File::join(node[:gearbox][:app_dir], artifact[:bag]["project_name"])
  tar_file = "#{artifact_dir}/tars/#{artifact_name}" 
  version_dir = "#{artifact_dir}/versions/#{artifact_name.sub(/\.tar\.gz/,'')}" 
  current_app_dir = File.join(artifact_dir, 'current')

  # create an application user and add it to the uwsgi and www-data
  # groups
  user artifact[:bag]['project_name'] do
    system true
  end

  directory artifact_dir do
    owner artifact[:bag]["project_name"]
    group node[:gearbox][:user]
    mode '0775'
    recursive true
  end

  [ node[:nginx][:user], node[:gearbox][:user] ].each do |grp|
    group grp do
      action :modify
      append true
      members artifact[:bag]["project_name"]
    end
  end

  # Download the artifact
  directory File::dirname(tar_file) do 
    owner artifact[:bag]["project_name"]
    group node[:gearbox][:user]
    action :create
    recursive true
  end

  file tar_file do
    action :create_if_missing
    content artifact[:bucket].value
    owner artifact[:bag]["project_name"]
    group node[:gearbox][:user]
  end

  # Untar it
  script "untar-#{artifact[:bag]['project_name']}" do
    interpreter "bash"
    user artifact[:bag]["project_name"]
    not_if { File.directory?(version_dir) }
    code <<-EOH
    mkdir -p "#{version_dir}"
    cd "#{version_dir}"
    tar -xzf "#{tar_file}"
    EOH
  end

  uwsgi_app = false
  # Instantiate the mustachios
  ruby_block "instantiate mustache" do
    block do
      require "mustache"
      require "pathname"
      template_dir = Pathname.new(File::join(version_dir, 'gbtemplate'))
      Mustache::template_path=template_dir
      compiled_dir = Pathname.new(File::join(version_dir, 'gbconfig'))

      #contest is node + loaded databags
      context = node.to_hash
      context["gearbox"]["loaded_data_bags"] = databags

      # find the templates
      Dir::glob("#{template_dir}/**/*.mustache").each do |file|
        # skip partials (templates that begin with _)
        next if (File.basename(file) =~ /^_/)

        # render the template
        Chef::Log.info("Expanding mustache template #{file}")
        template = Pathname.new(file.sub(/\.mustache$/,'')).relative_path_from(template_dir)
        target_file = File.join(compiled_dir, template)
        FileUtils.mkdir_p(File.dirname(target_file))
        File.open(target_file, "w") do |fh|
          fh.write(Mustache.render_file(template, context))
        end

      end



      # link uwsgi files
      if node[:uwsgi][:app_path] 
        uwsgi_app = false
        Dir::glob("#{compiled_dir}/uwsgi/**/*.yml").each do |source_file|
          target_file = source_file.sub("#{compiled_dir}/uwsgi", node[:uwsgi][:app_path] )
          File.delete(target_file) if File.exists?(target_file)
          FileUtils.mkdir_p(File.dirname(node[:uwsgi][:app_path])) unless File.exists?(node[:uwsgi][:app_path]) 
          Chef::Log.info("Linking source_file #{source_file} to target_file #{target_file}")
          File.symlink(source_file, target_file)
          uwsgi_app = true
        end
      end
    end
    action :create
  end

  if uwsgi_app
    group node[:uwsgi][:user] do
      action :modify
      append true
      members artifact[:bag]['project_name']
    end
  end

  # Create a link to the current deployment dir
  link current_app_dir do
    link_type :symbolic
    to version_dir
    Chef::Log.info(artifact[:bag]["project_name"])
    owner artifact[:bag]["project_name"]
    group node[:gearbox][:user]
  end

  # Create a logging directory
  directory File.join(artifact_dir, 'log') do 
    action :create
    recursive true
    owner artifact[:bag]['project_name']
    mode '0775'
    group node[:nginx][:user]
  end

  # Create a var directory
  directory File.join(artifact_dir, 'var') do 
    action :create
    recursive true
    owner artifact[:bag]['project_name']
    mode '0775'
    group node[:nginx][:user]
  end

  # Create the cache directory
  directory File.join(artifact_dir, 'cache') do
    action :create
    recursive true
    owner artifact[:bag]['project_name']
    mode '0775'
    group node[:nginx][:user]
  end

  # Create the cron jobs
  if artifact[:bag]['crontabs']
    artifact[:bag]['crontabs'].each_with_index do |task, index|
      cron "cron-#{artifact[:bag]['project_name']}-#{index}" do

        minute task['minute']   if task['minute']
        hour task['hour']       if task['hour']
        day task['day']         if task['day']
        month task['month']     if task['month']
        weekday task['weekday'] if task['weekday']
        path task['path']       if task['path']
        home task['home']       if task['home']
        shell task['shell']     if task['shell']
        user task['user']       if task['user']

        command "GB_APP_DIR=#{current_app_dir}; #{task['command']}"

      end
    end
  end
end

# Add nginx config
template "/etc/nginx/conf.d/gearbox.conf" do
  source "gearbox.conf.erb"
  owner node[:gearbox][:user]
  group node[:gearbox][:user]
  notifies :restart, resources(:service => :nginx)
end
