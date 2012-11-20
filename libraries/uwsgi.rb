def uwsgi_app(rendered_template, path, app_name)
    Chef::Log.info("Matching template: #{path}")

    target_file = ::File.join(node["uwsgi"]["app_path"], app_name)

    Chef::Log.info("Linking source_file #{.path} to target_file #{target_file}")

    source = path

    link target_file do
        action :nothing
        to source
    end.run_action(:create)

    file source do
        action :nothing
    end.run_action(:touch)
end
