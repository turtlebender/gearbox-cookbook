require 'digest/sha1'
require 'chef/mixin/checksum'
require 'chef/file_access_control'
require 'pathname'
require 'tempfile'
require 'chef/provider/file'

include ChefMustache::MustacheTemplate

def load_current_resource
    @current_resource = Chef::Resource::File.new(@new_resource.name)
    @current_resource
end

action :create do
    Chef::Log.info("Rendering mustache template: #{new_resource.path}")
    template = Pathname.new(@new_resource.source.sub(%r{\.mustache$}, ''))
    update = ::File.exist?(@new_resource.path)
    context = node.to_hash
    context = context.merge @new_resource.additional_context
    render_template(@new_resource.source, context) do |rendered_template|
        mode = @new_resource.mode
        owner = @new_resource.owner
        group = @new_resource.group
        target = @new_resource.path.dup
        file @new_resource.path.dup do
            action :nothing
            content rendered_template
            mode mode
            owner owner
            group group
        end.run_action(:create)

        # Copy upstart files
        if ( @new_resource.path =~ %r{.*/upstart/.*} )
            upstart_config_template rendered_template, @new_resource.path
        end

        if ( @new_resource.path =~ %r{.*/uwsgi/(.*.yaml)} )
            uwsgi_app_template rendered_template, @new_resource.path, $1
        end

        if ( @new_resource.path =~ %r{.*/nginx/(.*)} )
            nginx_site_template rendered_template, $1
        end
    end
end
