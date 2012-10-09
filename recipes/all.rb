apps = node[:gearbox][:apps].map do |appname|
      data_bag_item("gearbox", appname) 
end

apps.each do |app|
    gearbox_app app["name"] do
        version app["version"]
        bucket node["gearbox"]["artifact_bucket"]
    end
end
