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

%w{libglobus-gss-assist-dev libglobus-gsi-credential-dev libglobus-gsi-sysconfig-dev libglobus-gsi-cert-utils-dev libglobus-gsi-cert-utils0 libglobus-usage-dev myproxy libxslt1-dev libxml2-dev}.each do |pkg|
  package pkg
end
