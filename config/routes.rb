Rails.application.routes.draw do
  devise_for :admin_users, ActiveAdmin::Devise.config
  ActiveAdmin.routes(self)
  devise_for :users
  # The priority is based upon order of creation: first created -> highest priority.
  # See how all your routes lay out with "rake routes".

  # You can have the root of your site routed with "root"
  root 'main#index'
  get 'index(.:format)' => 'main#index'

  resources :datasets
  resources :dataset_rows
  resources :runs do
    member do
      get 'visualize'
    end
  end
  resources :runsets do
    member do
      get 'results'
    end
  end

  # authenticate: enable djmon route only for authenticated admins, otherwise redirect to admin login
  # authenticated: will just throw 404 without login redirection
  # when embedding this route in iframe inside activeadmin, browser will block the redirection (authenticate)
  authenticated :admin_user do
    match "/admin/djmon" => DelayedJobWeb, :anchor => false, via: [:get, :post]
  end

end