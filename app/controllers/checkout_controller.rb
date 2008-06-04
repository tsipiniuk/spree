class CheckoutController < Spree::BaseController
  before_filter :new_or_login
  before_filter :find_order, :except => [:index, :thank_you]
    
  def index
    find_cart
    # remove any incomplete orders in the db associated with the session
    session[:order_id] = nil

    if @cart.nil? || @cart.cart_items.empty?
      render :template => 'checkout/empty_cart' and return
    end
    redirect_to :action => :addresses
  end

  def addresses
    @user = current_user ? current_user : User.new
    @states = State.find(:all, :order => 'name')
    @countries = Country.find(:all)
    
    if request.post?
      @different_shipping = params[:different_shipping]
      @bill_address = Address.new(params[:bill_address])
      #if only one country available there will be no choice (and user will post nothing)
      @bill_address.country ||= Country.find(:first)


      params[:ship_address] = params[:bill_address].dup unless params[:different_shipping]
      @ship_address = Address.new(params[:ship_address])
      @ship_address.country ||= Country.find(:first)      

      render :action => 'addresses' and return unless @user.valid? and @bill_address.valid? and 
        @ship_address.valid?      

      @order.bill_address = @bill_address
      @order.ship_address = @ship_address
      @order.user = @user
      
      #if only one shipping method available there will be no choice (and user will post nothing)
      @order.ship_method = params[:order][:ship_method] if params[:order]
      @order.ship_method ||= 1

      @order.ship_amount = calculate_shipping(@order)
      @order.save
          
      redirect_to :action => 'final_confirmation'
    end
  end
  
  def final_confirmation 
    if request.post?
      @cc = ActiveMerchant::Billing::CreditCard.new(params[:creditcard])
      @cc.first_name = @order.bill_address.firstname
      @cc.last_name = @order.bill_address.lastname
      
      @order.number = Order.generate_order_number 
      @order.ip_address =  request.env['REMOTE_ADDR']

      render :action => 'final_confirmation' and return unless @cc.valid?      
  
      # authorize creditcard
      response = authorize_creditcard(@cc)
      
      unless response.success?
        # TODO - optionally handle gateway down scenario by accepting the order and putting into a special state
        msg = "Problem authorizing credit card ... \n#{response.params['error']}"
        logger.error(msg)
        flash[:error] = msg
        render :action => 'final_confirmation' and return
      end
      
      # Note: Create an ActiveRecord compatible object to store in our database
      @order.credit_card = CreditCard.new_from_active_merchant(@cc)
      @order.credit_card.txns << Txn.new(
        :amount => @order.total,
        :response_code => response.authorization,
        :txn_type => Txn::TxnType::AUTHORIZE
      )

      @order.status = Order::Status::AUTHORIZED  
      finalize_order

      # send email confirmation
      OrderMailer.deliver_confirm(@order)
      redirect_to :action => :thank_you, :id => @order.id and return
    else
      @order.ship_amount = calculate_shipping(@order)
      # NOTE: calculate_tax method will be mixed in by the TaxCalculator extension
      calculate_tax(@order)
    end
  end
  
  def comp
    @order.number = Order.generate_order_number 
    @order.ip_address =  request.env['REMOTE_ADDR']

    @order.line_items.each do |li|
      li.price = 0
    end
    @order.ship_amount = 0
    @order.tax_amount = 0
    
    @order.order_operations << OrderOperation.new(
      :operation_type => OrderOperation::OperationType::COMP,
      :user => current_user
    )

    @order.status = Order::Status::PAID
    finalize_order

    # send email confirmation
    OrderMailer.deliver_confirm(@order)
    
    redirect_to :action => :thank_you, :id => @order.id and return
  end
  
  def thank_you
    @order = Order.find(params[:id])
  end
  
  def cvv
    render :layout => false
  end
  
  private
      def find_order
        id = session[:order_id]
        unless id.blank?
          @order = Order.find(id)
        else
          @order = Order.new_from_cart(find_cart)
          @order.status = Order::Status::INCOMPLETE
          @order.save
          session[:order_id] = @order.id    
          @order
        end
      end
      
      def new_or_login
        # create a new user (or login an existing one)
        return if logged_in?
        redirect_to new_user_url
      end

      def finalize_order
        Order.transaction do
          if @order.save
            InventoryUnit.adjust(@order)
            session[:order_id] = nil
            # destroy cart (if applicable)
            cart = find_cart
            cart.destroy unless cart.new_record?
            session[:cart_id] = nil
          else
            logger.error("problem with saving order " + @order.inspect)
            redirect_to :action => :incomplete
          end        
        end
      end
      
      def authorize_creditcard(creditcard)
        gw = payment_gateway 
        # ActiveMerchant is configured to use cents so we need to multiply order total by 100
        gw.authorize(@order.total * 100, creditcard, Order.gateway_options(@order))
      end
      
      def calculate_shipping(order)
        # convert the enumeration into the title, replace spaces so we can convert to class
        sm = (Order::ShipMethod.from_value order.ship_method).sub(/ /, '')
        sc = sm.constantize.new
        sc.shipping_cost(order)
      end
end
