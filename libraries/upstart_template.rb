def upstart_config_template( rendered_template, path )
            upstart_regex = %r{.*/(.*)\.conf}
            service_name = upstart_regex.match(path)[1]
    upstart_config = file "/etc/init/#{service_name}.conf" do
        content rendered_template
        action :nothing
    end

    upstart_config.run_action(:create)

    service = service service_name do
        provider Chef::Provider::Service::Upstart
        action :nothing
    end

    if upstart_config.updated?
        service.run_action(:enable)
        service.run_action(:restart)
    end
end

