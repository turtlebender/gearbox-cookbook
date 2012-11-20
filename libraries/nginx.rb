# Write an nginx template to the nginx directory and then enable the site
def nginx_site(rendered_template, site_name)
    Chef::Log.info("Matching template: #{@new_resource.path}")
    # This is the standard directory for nginx sites
    sites_directory = "#{node["nginx"]["dir"]}/sites-available"
    target_file = ::File.join(sites_directory, site_name)
    # This really shouldn't be necessary since we assume nginx is installed, but whatever
    directory sites_directory do
        action :nothing
        owner node["nginx"]["user"]
        group node["nginx"]["user"]
        mode "0755"
    end.run_action(create)

    nginx_config = file "#{sites_directory}/#{site_name}" do
        content rendered_template
        action :nothing
        owner node["nginx"]["user"]
        group node["nginx"]["user"]
        mode "0644"
    end.run_action(:create)

    nginx_site site_name do
        enable true
    end
end
