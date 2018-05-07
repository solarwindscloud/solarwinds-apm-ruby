##
# Copyright (c) 2016 SolarWinds, LLC.
# All rights reserved.

#  This is a Rails stack that launches on a background
#  thread and listens on port 8140.
#
require "rails/all"
require "action_controller/railtie" # require more if needed
require 'rack/handler/puma'
require File.expand_path(File.dirname(__FILE__) + '/../models/widget')

AppOpticsAPM.logger.info "[appoptics_apm/info] Starting background utility rails app on localhost:8140."
if ENV['DBTYPE'] == 'mysql2'
  AppOpticsAPM::Test.set_mysql2_env
elsif ENV['DBTYPE'] =~ /postgres/
  AppOpticsAPM::Test.set_postgresql_env
else
  AppOpticsAPM.logger.warn "Unidentified DBTYPE: #{ENV['DBTYPE']}"
  AppOpticsAPM.logger.debug "Defaulting to postgres DB for background Rails server."
  AppOpticsAPM::Test.set_postgresql_env
end

ActiveRecord::Base.establish_connection(ENV['DATABASE_URL'])

unless ActiveRecord::Base.connection.table_exists? 'widgets'
  ActiveRecord::Migration.run(CreateWidgets)
end

class Rails50MetalStack < Rails::Application
  routes.append do
    get "/hello/world"       => "hello#world"
    get "/hello/:id/show"    => "hello#show"
    get "/hello/metal"       => "ferro#world"
    get "/hello/db"          => "hello#db"
    get "/hello/servererror" => "hello#servererror"

    post "/widgets"          => "widgets#create"
    get "/widgets/:id"       => "widgets#show"
    put "/widgets/:id"       => "widgets#update"
    delete "/widgets/:id"    => "widgets#destroy"
  end

  config.cache_classes = true
  config.eager_load = false
  config.active_support.deprecation = :stderr
  config.middleware.delete Rack::Lock
  config.middleware.delete ActionDispatch::Flash
  config.secret_token = "49837489qkuweoiuoqwehisuakshdjksadhaisdy78o34y138974xyqp9rmye8yrpiokeuioqwzyoiuxftoyqiuxrhm3iou1hrzmjk"
  config.secret_key_base = "2048671-96803948"
end

#################################################
#  Controllers
#################################################

class HelloController < ActionController::Base
  def world
    render :plain => "Hello world!"
  end

  def show
    render :plain => "Hello Number #{params[:id]}"
  end

  def db
    # Create a widget
    w1 = Widget.new(:name => 'blah', :description => 'This is an amazing widget.')
    w1.save

    # query for that widget
    w2 = Widget.where(:name => 'blah').first
    w2.delete

    render :plain => "Hello database!"
  end

  def servererror
    render :plain => "broken", :status => 500
  end
end

class WidgetsController < ActionController::Base
  protect_from_forgery with: :null_session

  def show
    if widget = Widget.find(params[:id].to_i)
      render :json => widget
    else
      render :json => { :error => 'Widget NOT found' }, :status => 500
    end
  end

  def update
    if widget = Widget.update(params[:id].to_i, widget_params.to_h.symbolize_keys)
      render :json => widget
    else
      render :json => { :error => 'Widget NOT updated' }, :status => 500
    end
  end

  def create
    widget = Widget.new(widget_params.to_h.symbolize_keys)
    if widget.save
      render :json => widget
    else
      render :json => { :error => 'Widget NOT created' }, :status => 500
    end
  end

  def destroy
    if Widget.delete(params[:id].to_i) != 0
      render :plain => 'Widget destroyed'
    else
      render :plain => 'Widget NOT destroyed', :status => 500
    end
  end

  private

  def widget_params
    params.require(:widget).permit(:name, :description)
  end

end

class FerroController < ActionController::Metal
  include AbstractController::Rendering

  def world
    render :plain => 'Hello world!'
  end
end

AppOpticsAPM::API.profile_method(FerroController, :world)

Rails50MetalStack.initialize!

Thread.new do
  Rack::Handler::Puma.run(Rails50MetalStack.to_app, {:Host => '127.0.0.1', :Port => 8140})
end

sleep(2)
