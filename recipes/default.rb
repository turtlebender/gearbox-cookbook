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
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# 

# Get the databags associated with the specific apps

# We need aws-s3 now!
gem_package "aws-s3" do
  action :install
  version "0.6.3"
end.run_action(:install)
gem_package "mustache" do
  action :install
  version "0.99.4"
end.run_action(:install)
Gem.clear_paths

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
  prefix = "#{bag['project_name']}/#{node[:chef_environment]}"
  bucket = AWS::S3::Bucket.objects(node[:gearbox][:artifact_bucket], :prefix => prefix).sort_by(&:key).last
  raise RuntimeError.new("Failed to find artifact for #{bag["project_name"]}.") if bucket.nil?
  { :bag => bag, :bucket => bucket }
end.reject(&:nil?)


# Install each artifact

artifacts.each do |artifact|
  artifact_name = File::basename(artifact[:bucket].key)
  artifact_dir = File::join(node[:gearbox][:app_dir], artifact[:bag]["project_name"])
  tar_file = "#{artifact_dir}/tars/#{artifact_name}" 
  version_dir = "#{artifact_dir}/versions/#{artifact_name.sub(/\.tar\.gz/,'')}" 

  # Download the artifact
  directory File::dirname(tar_file) do 
    action :create
    recursive true
  end

  file tar_file do
    action :create_if_missing
    content artifact[:bucket].value
  end

  # Untar it
  script "untar" do 
    interpreter "bash"
    user "root"
    not_if { File.directory?(version_dir) }
    code <<-EOH
    mkdir -p #{version_dir}
    cd #{version_dir}
    tar -xzf #{tar_file} 
    EOH
  end

  # Instantiate the mustachios
  ruby_block "instantiate mustache" do
    block do
      require "mustache"
      require "pathname"
      template_dir = Pathname.new(File::join(version_dir, 'gbtemplate'))
      Mustache::template_path=template_dir
      compiled_dir = Pathname.new(File::join(version_dir, 'gbconfig'))
      Dir::glob("#{template_dir}/**/*.mustache").each do |file|
        Chef::Log.info("Expanding mustache template #{file}")
        template = Pathname.new(file.sub(/\.mustache$/,'')).relative_path_from(template_dir)
        target_file = File.join(compiled_dir, template)
        FileUtils.mkdir_p(File.dirname(target_file))
        File.open(target_file, "w") do |fh|
          fh.write(Mustache.render_file(template, node))
        end
      end
    end
    action :create
  end

  link File.join(artifact_dir, 'current') do
    link_type :symbolic
    to version_dir
  end
end

# Add nginx config
template "/etc/nginx/conf.d/gearbox.conf" do
  source "gearbox.conf.erb"
  notifies :restart, resources(:service => :nginx)
end
  
