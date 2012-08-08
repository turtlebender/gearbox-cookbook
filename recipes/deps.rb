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
 
# We need aws-s3 now!
gem_package "aws-s3" do
  action :install
  version "0.6.3"
  options "--no-ri --no-rdoc"
end.run_action(:install)
gem_package "mustache" do
  action :install
  version "0.99.4"
  options "--no-ri --no-rdoc"
end.run_action(:install)
Gem.clear_paths
directory "/var/lib/globus/downloads" do
  action :create
  recursive true
end

bash "update_apt" do
  code <<-eof
dpkg -i /var/lib/globus/downloads/globus-repository-maverick_0.0.1_all.deb
apt-get update
  eof
  action :nothing
end

remote_file "/var/lib/globus/downloads/globus-repository-maverick_0.0.1_all.deb" do
  action "create_if_missing"
  source "http://www.globus.org/ftppub/gt5/5.1/5.1.1/installers/repo/globus-repository-maverick_0.0.1_all.deb"
  checksum "76deac457"
  notifies :run, "bash[update_apt]", :immediately
end

%w{libglobus-gss-assist-dev libglobus-gsi-credential-dev libglobus-gsi-sysconfig-dev libglobus-gsi-cert-utils-dev libglobus-gsi-cert-utils0 libglobus-usage-dev myproxy libxslt1-dev libxml2-dev dictionaries-common wamerican-large}.each do |pkg|
  package pkg
end
