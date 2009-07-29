class UsersController < ApplicationController

    requires_authentication :except => [:login, :complete_openid_login, :logout, :forgot_password, :new, :create]
    
    def load_user
        @user = User.find_by_username(params[:id]) || User.find(params[:id]) rescue nil
        unless @user
            flash[:notice] = "User not found!"
            redirect_to users_url and return
        end
    end
    protected     :load_user
    before_filter :load_user, :only => [:show, :edit, :update, :destroy, :participated, :discussions, :posts, :update_openid, :grant_invite, :revoke_invites]
    
    def index
        @users  = User.find(:all, :order => 'username ASC', :conditions => 'activated = 1 AND banned = 0')
		respond_to do |format|
			format.html {}
			format.json {
				render :layout => false, :text => @users.to_json(:only => [:id, :username, :realname, :latitude, :longitude, :last_active, :created_at, :description, :admin, :moderator, :user_admin, :posts_count, :discussions_count, :location, :gamertag, :avatar_url, :twitter, :flickr, :website])
			}
		end
    end

    def banned
        @users  = User.find(:all, :order => 'username ASC', :conditions => 'banned = 1')
    end

	def recently_joined
		@users = User.find_new
	end

	def online
		@users = User.find_online
	end
	
	def admins
        @users  = User.find_admins
	end
    
    def xboxlive
        @users = XboxInfo.valid_users
    end

	def twitter
		@users = User.find_twitter_users
	end
	
	def top_posters
		@users = User.find_top_posters(:limit => 50)
	end
	
	def map
	end
    
	def trusted
		unless @current_user && @current_user.trusted?
			flash[:notice] = "You need to be trusted to view this page!"
		end
		@users = User.find_trusted
	end

    def show
		respond_to do |format|
			format.html do
				@posts = @user.paginated_posts(:page => params[:page], :trusted => @current_user.trusted?, :limit => 15)
			end
			format.iphone {}
		end
    end
    
    def discussions
        @discussions = @user.paginated_discussions(:page => params[:page], :trusted => @current_user.trusted?)
        find_discussion_views
    end
    
	def participated
		@section = :participated if @user == @current_user
		@discussions = @user.participated_discussions(:page => params[:page], :trusted => @current_user.trusted?)
		find_discussion_views
	end
	
	def posts
		@posts = @user.paginated_posts(:page => params[:page], :trusted => @current_user.trusted?)
	end

    def new
		# New by invitation
		if params[:token]
			@invite = Invite.first(:conditions => {:token => params[:token]})
			if @invite && !@invite.expired?
				@user = @invite.user.invitees.new
				@user.email = @invite.email
			else
				flash[:notice] = "That's not a valid invite!"
				redirect_to login_users_url and return
			end
		# Signups allowed
		elsif Sugar.config(:signups_allowed)
			@user = User.new
		else
			flash[:notice] = "Signups are not allowed!"
			redirect_to login_users_url and return
		end
    end

    def create
		if params[:token]
			@invite = Invite.first(:conditions => {:token => params[:token]})
			@invite = nil if @invite.expired?
		end
		
		unless Sugar.config(:signups_allowed) || @invite
			flash[:notice] = "Signups are not allowed!"
			redirect_to login_users_url and return
		end

		# Secure and parse attributes
		attributes = User.safe_attributes(params[:user])
		if attributes[:openid_url] && !attributes[:openid_url].blank?
			new_openid_url = attributes[:openid_url]
		end
		attributes[:username]   = params[:user][:username]
		attributes[:inviter_id] = @invite.user_id if @invite
		attributes[:activated]  = Sugar.config(:signup_approval_required) ? false : true

		@user = User.create(attributes)
		if @user.valid?
			@invite.expire! if @invite
			Notifications.deliver_new_user(@user, login_users_path(:only_path => false))
			@current_user = @user
			store_session_authentication
			
			# Verify the changed OpenID URL
			if new_openid_url
				response = openid_consumer.begin(new_openid_url) rescue nil
				if response
					redirect_to response.redirect_url(root_url, update_openid_user_url(:id => @user.username), false) and return
				else
					flash[:notice] = "WARNING: Your OpenID URL is invalid!"
				end
			end
			redirect_to user_url(:id => @user.username) and return
		else
			flash.now[:notice] = "Could not create your account, please fill in all required fields."
			render :action => :new
		end
    end

    def edit
        # TODO: refactor to .editable_by?
        require_user_admin_or_user(@user, :redirect => user_url(@user))
    end

	def update_openid
        require_user_admin_or_user(@user, :redirect => user_url(@user))
		response_params = params
		response_params.delete(:controller)
		response_params.delete(:action)
		response_params.delete(:id)
		response = openid_consumer.complete(response_params, update_openid_user_url(:id => @user.username))

		case response
		when OpenID::Consumer::SetupNeededResponse
			setup_url = response.instance_eval{ @setup_url } rescue nil
			raise setup_url.inspect
			if setup_url
				redirect_to setup_url and return
			else
				setup_response = openid_consumer.begin(response.identity_url) rescue nil
				if setup_response
					redirect_to setup_response.redirect_url(root_url, update_openid_user_url(:id => @user.username)) and return
				end
			end
		when OpenID::Consumer::SuccessResponse
			if @user.update_attribute(:openid_url, OpenID.normalize_url(response.identity_url))
				flash[:notice] = "Your OpenID URL was updated!"
				redirect_to user_url(:id => @user.username) and return
			end
		when OpenID::Consumer::FailureResponse
			# Do nothing
		end
		
		flash[:notice] ||= 'OpenID verification failed!'
		redirect_to edit_user_url(:id => @user.username)
	end
    
	def update
        require_user_admin_or_user(@user, :redirect => user_url(@user))
		attributes = @current_user.admin? ? params[:user] : User.safe_attributes(params[:user])

		if attributes[:openid_url] && !attributes[:openid_url].blank? && attributes[:openid_url] != @user.openid_url
			new_openid_url = attributes[:openid_url]
			attributes.delete(:openid_url)
		end

		@user.update_attributes(attributes)
		if @user.valid?
			if @user == @current_user
				# Make sure the session data is updated
				@current_user.reload
				store_session_authentication
			end
			# Verify the changed OpenID URL
			if new_openid_url
				response = openid_consumer.begin(new_openid_url) rescue nil
				if response
					redirect_to response.redirect_url(root_url, update_openid_user_url(:id => @user.username), false) and return
				else
					flash.now[:notice] = "That's not a valid OpenID URL!"
				end
			else
				flash[:notice] = "Your changes were saved!"
				redirect_to user_url(:id => @user.username) and return
			end
		end
		flash.now[:notice] ||= "There were errors saving your changes"
		render :action => :edit
	end

	def complete_openid_login
		response_params = params
		response_params.delete(:controller)
		response_params.delete(:action)
		response = openid_consumer.complete(response_params, complete_openid_login_users_url)

		case response
		when OpenID::Consumer::SetupNeededResponse
			setup_url = response.instance_eval{ @setup_url } rescue nil
			if setup_url
				redirect_to setup_url and return
			else
				setup_response = openid_consumer.begin(response.identity_url) rescue nil
				if setup_response
					redirect_to setup_response.redirect_url(root_url, complete_openid_login_users_url) and return
				end
			end
		when OpenID::Consumer::SuccessResponse
			user = User.first(:conditions => {:openid_url => OpenID.normalize_url(response.identity_url)})
			if user
				if user.activated? && !user.banned?
                    @current_user = user
                    store_session_authentication
					redirect_to discussions_url and return
				else
					flash[:notice] = "You're not allowed to log in!"
				end
			else
				flash[:notice] = 'There are no users registered with that identity URL.'
			end
		when OpenID::Consumer::FailureResponse
			# Do nothing
		end
		
		flash[:notice] ||= 'OpenID login failed.'
		redirect_to login_users_url
	end
    
    def login
        redirect_to discussions_url and return if @current_user
        if request.post?
			if params[:username] && params[:password] && !params[:username].blank? && !params[:password].blank?
                user = User.find_by_username(params[:username])
                if user && user.valid_password?(params[:password])
                    @current_user = user
                    store_session_authentication
                    redirect_to discussions_url and return
                end
			elsif params[:openid_url] && !params[:openid_url].blank?
				openid_url = params[:openid_url]
				response = openid_consumer.begin(openid_url) rescue nil
				if response
					redirect_to response.redirect_url(root_url, complete_openid_login_users_url, false) and return
				else
					flash.now[:notice] = "That's not a valid OpenID URL!"
				end
			end
            flash.now[:notice] ||= "<strong>Oops!</strong> That’s not a valid username or password." unless @current_user
        end
        render :layout => 'login'
    end
    
    def forgot_password
        @user = User.find_by_email(params[:email])
        if @user
            if @user.activated? && !@user.banned?
                @user.generate_password!
                Notifications.deliver_password_reminder(@user, login_users_path(:only_path => false))
                @user.save
                flash[:notice] = "A new password has been mailed to you"
            else
                flash[:notice] = "Your account isn't active, you can't do that yet"
            end
        else
            flash[:notice] = "<strong>Oops!</strong> Couldn't find your email address."
        end
        redirect_to login_users_url
    end
    
    def logout
        deauthenticate!
        redirect_to login_users_url
    end

	def grant_invite
		unless @current_user.user_admin?
			flash[:notice] = "You don't have permission to do that!"
			redirect_to user_url(:id => @user.username) and return
		end
		@user.grant_invite!
		flash[:notice] = "#{@user.username} has been granted one invite."
		redirect_to user_url(:id => @user.username) and return
	end

	def revoke_invites
		unless @current_user.user_admin?
			flash[:notice] = "You don't have permission to do that!"
			redirect_to user_url(:id => @user.username) and return
		end
		@user.revoke_invite!(:all)
		flash[:notice] = "#{@user.username} has been revoked of all invites."
		redirect_to user_url(:id => @user.username) and return
	end
end
