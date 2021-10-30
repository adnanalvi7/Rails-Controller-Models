class Api::V1::JobsController < Api::V1::BaseController
  before_action :set_repair_shop, only: %i[index create destroy add_payment update_custom_supplies update_tax qa_checklist_job_items send_nps_fedback_email]

  before_action :set_customer, only: [:final_checklist]
  before_action :set_job, only: [:final_checklist]
  before_action :find_job, except: %i[index create final_checklist add_job_photos job_all_items job_items_list single_job_item]

  before_action :find_job_record, only: [:job_all_items, :job_items_list, :single_job_item]
  before_action :set_crs, only: :show
  before_action :authorized_user, only: [:destroy]

  before_action :authorized_technician, except: %i[index create active_coupons job_items job_all_items job_items_list get_customer_concerns_diagnostics_and_job_items job_photos estimate final_checklist qa_checklist_job_items], if: :is_user_technician?
  before_action :get_vcdb_base_vehicle, only: [:show, :update]
  before_action :can_update_job?, only: :update
  before_action :set_job_items, only: [:single_job_item, :job_all_items, :job_items_list]
  after_action :send_nps_fedback_email, only: [:close_job]

  # GET /api/v1/profiles/:random_id/jobs
  resource_description do
    short I18n.t('api.docs.resources.jobs.short_desc')
    path '/v1/jobs'
  end

  api :GET, '/:repairshop_id/jobs', I18n.t('api.docs.resources.jobs.index.short_desc')
  error code: 400, desc: I18n.t('api.docs.resources.common.errors.bad_request')
  description I18n.t('api.docs.resources.jobs.index.full_desc')

  def index
    params[:page] ||= 1
    params[:per_page] ||= 20
    params[:field] ||= 'created_at'
    params[:order] ||= 'ASC'
    if params[:q]
      @open_jobs = params[:q].present? ? @repair_shop.jobs.index_ros(params[:ros], current_user).search(params[:q]) : @repair_shop.jobs.index_ros(params[:ros], current_user)
      @jobs = pagy(@open_jobs.order('created_at').reverse_order,page: params[:page], items: params[:per_page])
    else
      @open_jobs = params[:q].present? ? @repair_shop.jobs.index_ros(params[:ros], current_user).search(params[:q]) : @repair_shop.jobs.index_ros(params[:ros], current_user)
      if params[:field] == 'created_at'
        @jobs = pagy(@open_jobs.includes(:customer, :vehicle, :technician).order('created_at').reverse_order,  page: params[:page], items: params[:per_page])
      else
        @jobs = pagy(@open_jobs.includes(:customer, :vehicle, :technician).order("#{params[:field]} #{params[:order]}"), page: params[:page], items: params[:per_page])
        @jobs = pagy(@jobs.order("#{params[:field].split('.').first}.created_at DESC"), page: params[:page], items: params[:per_page])
      end
    end
  end

  api :POST, '/jobs', I18n.t('api.docs.resources.jobs.create.short_desc')
  param :dont_text, :bool, required: false
  param :estimated_repair_time, :number, required: false
  param :mileage_in, :number, required: false
  param :mileage_out, :number, required: false
  param :profit_center_id, :number, required: true
  param '[technician_attributes][name]', :string, required: false
  param '[vehicle_attributes][vin]', :string, required: false
  param '[vehicle_attributes][customer_attributes][name]', :string, required: false
  param '[vehicle_attributes][customer_attributes][phone]', :number, required: false
  param '[vehicle_attributes][customer_attributes][email]', :email_address, required: false
  param '[vehicle_attributes][customer_attributes][address]', :string, required: false
  error code: 403, desc: I18n.t('api.docs.resources.common.errors.forbidden')
  error code: 400, desc: I18n.t('api.docs.resources.common.errors.bad_request')
  error code: 401, desc: I18n.t('api.docs.resources.common.errors.token_expired')
  error code: 422, desc: I18n.t('api.docs.resources.common.errors.invalid_resource')
  description I18n.t('api.docs.resources.jobs.create.full_desc')

  def create
    res = VehicleParams.new(params).handle_with_vehicle_params
    return render_vehicle_error if res[0] == 'render_vehicle_error' && @existing_job = res[1]
    return render_another_customer_error if res[0] == 'another_customer_error' && @existing_vehicle = res[1]

    params = res

    parse_profit_center_id
    @job = @repair_shop.jobs.new(job_create_params)
    @job.coupons << Coupon.find(params[:coupon_ids]) if params[:coupon_ids]

    # set customer repair shop for job
    set_job_crs
    if @job.save
      if params[:vehicle_attributes].present? && params[:vehicle_attributes][:motor_vehicle_data].present? &&  @job.present?
        veh = Vehicle.new.data(params[:vehicle_attributes][:motor_vehicle_data], @job.vehicle.id, @job.vehicle.vin)
        @job.vehicle.update(veh) if veh.present? && @job.vehicle.present?
      end
      @job.vehicle.update(previous_viscosity: params[:previous_viscosity]) if params[:previous_viscosity].present?
      @job.vehicle.update(unit_id: params[:vehicle_unit_id]) if params[:vehicle_unit_id].present?
      @job.customer.update(customer_update_params[:customer_attributes]) if params[:vehicle_attributes].present? && customer_update_params[:customer_attributes].present?
      @job.fleet.update(autodata_id: params[:fleet_attributes][:autodata_id]) if params[:fleet_attributes]
      @job.update_customer_static
      @job.save
      if params[:job_items_attributes].present?
        if params[:create_estimate] == 'create_estimate'
          @job.build_estimate params[:job_items_attributes]
        else
          @job.create_operation_line_items params[:job_items_attributes]
        end
      end
      render @job
    else
      render(json: { errors: @job.errors, crs_id: @crs&.id }, status: :bad_request) && return
    end
  end

  def show; end

  def job_calculations; end

  def calculations
    @job = Job.where(id: params[:id]).first
  end

  api :PATCH, '/api/v1/:repair_shop_id/jobs/:id', I18n.t('api.docs.resources.jobs.update.short_desc')
  param :vehicle_id, :number, required: false
  param :dont_text, :bool, required: false
  param :state, :string, required: false
  error code: 400, desc: I18n.t('api.docs.resources.common.errors.bad_request')
  error code: 403, desc: I18n.t('api.docs.resources.common.errors.forbidden')
  description I18n.t('api.docs.resources.jobs.update.full_desc')

  def update
    parse_profit_center_id
    @job.coupons << Coupon.find(params[:coupon_ids]) if params[:coupon_ids]
    if (params[:customer_details].present? || params[:customer_attributes].present?) && !params[:reassign_customer]
      res = VehicleParams.new(params).handle_with_vehicle_params(true)
      return render_another_customer_error if res[0] == 'another_customer_error' && @existing_vehicle = res[1]
    end

    if params[:vehicle_attributes].present?
      res = VehicleParams.new(params, @job).save_vehicle_data
      return render_vehicle_error if !res[0] && @existing_job = res[1]
    end

    set_job_crs
    if @job.update(job_update_params)
      if params[:vehicle_attributes]
        if params[:vehicle].present? && params[:vehicle][:id] != params[:vehicle_attributes][:id] && @job&.appointment.present?
          @job&.appointment&.update(vehicle_id: params[:vehicle_attributes][:id])
        end
        if params[:vehicle_attributes][:motor_vehicle_data].present? && params[:vehicle_attributes][:id]
          veh = Vehicle.new.data(params[:vehicle_attributes][:motor_vehicle_data], params[:vehicle_attributes][:id], params[:vehicle_attributes][:vin])
          @job.vehicle.update(veh) if veh.present?
        end
      end
      @job.set_job_item_technician if params[:update_techs].present? && @job.technician_id?
      @job.add_remove_job_items params['job_items'] if params['job_items']
      @job.create_note(params, current_user.id)
      @job.customer.update(customer_update_params[:customer_attributes]) if params[:vehicle_attributes].present? && customer_update_params[:customer_attributes].present?
      @job.fleet.update(autodata_id: params[:fleet_attributes][:autodata_id]) if params[:fleet_attributes]
      @job.update_customer_static
      @job.save
      render @job
    else
      render(json: { errors: @job.errors }, status: :bad_request) && return
    end
  end

  api :PATCH, '/:repair_shop_id/jobs/:id/update_technician_oversight', I18n.t('api.docs.resources.jobs.update_technician_oversight.short_desc')
  error code: 400, desc: I18n.t('api.docs.resources.common.errors.bad_request')
  description I18n.t('api.docs.resources.jobs.update_technician_oversight.full_desc')
  def update_technician_oversight
    if params[:oversight_details].present? && @job.update_technician_oversight(params[:oversight_details])
      render json: {status: :success}
    else
      render(json: { errors: @job.errors, crs_id: @crs&.id }, status: :bad_request) && return
    end
  end

  api :PATCH, '/:repair_shop_id/jobs/:id/update_cashier', I18n.t('api.docs.resources.jobs.update_cashier.short_desc')
  error code: 400, desc: I18n.t('api.docs.resources.common.errors.bad_request')
  description I18n.t('api.docs.resources.jobs.update_cashier.full_desc')

  def update_cashier_and_advisor
    if @job.update_cashier_and_advisor(params[:cashier_id], params[:advisor_id])
      render json: {status: :success}
    else
      render(json: { errors: @job.errors }, status: :bad_request) && return
    end
  end

  def update_custom_supplies
    @job.update(custom_supplies: params[:custom_supplies])
    get_total_tax = @job.get_total_tax('estimate')
    grand_total = @job.grand_total('estimate')
    remaining_balance  = @job.remaining_balance('estimate', nil, nil, grand_total)
    if grand_total && @job.grand_total_amount != grand_total
        @job.grand_total_amount = grand_total
        @job.save
    end
    render(json: { notice: 'Custom charge applied successfully.', items: [get_total_tax, grand_total, @job.custom_supplies, remaining_balance] }, status: :ok) && return
  end

  def update_tax_rate
    @job.update(part_tax_rate: params[:tax_rate], supplies_tax_rate: params[:tax_rate], custom_tax: true)
    get_total_tax = @job.get_total_tax('estimate')
    grand_total = @job.grand_total('estimate')
    remaining_balance  = @job.remaining_balance('estimate', nil, nil, grand_total)
    if grand_total && @job.grand_total_amount != grand_total
        @job.grand_total_amount = grand_total
        @job.save
    end
    render(json: { notice: 'Custom tax successfully.', items: [get_total_tax, grand_total, remaining_balance] }, status: :ok) && return
  end

  # delete job_items and estimate_items using operation
  api :DELETE, '/:repair_shop_id/jobs/:id/delete_job_items/:job_item_id', I18n.t('api.docs.resources.jobs.delete_job_items.short_desc')
  error code: 400, desc: I18n.t('api.docs.resources.common.errors.bad_request')
  description I18n.t('api.docs.resources.jobs.delete_job_items.full_desc')

  def delete_job_items
    @job_item = JobItem.find params[:job_item_id]
    @job_item.destroy
    @job_item.job.update_flag
    render(json: { notice: 'Deleted job item' }, status: :ok) and return
  end

  # mark_job_as_warranty_or_policy
  def mark_job_as_warranty_or_policy
    if DefectiveOperation.where(job_id: @job.id).present?
      @defective_operation = DefectiveOperation.find_by(job_id: @job.id)
      @defective_operation.update(name: params[:operation_name], job_id: @job.id, job_item_id: params[:previous_job_item_id]) if params[:warranty_or_policy]
    elsif params[:warranty_or_policy]
      DefectiveOperation.create(name: params[:operation_name], job_id: @job.id, job_item_id: params[:previous_job_item_id])
    end

    @job.job_items.each do |job_item|
      job_item.warranty_or_policy = params[:warranty_or_policy]
      job_item.save
    end
    @job.warranty_or_policy = params[:warranty_or_policy]

    if @job.save
      render json: {status: :ok}
    else
      render(json: {errors: @job.errors.messages}, status: :bad_request) && return
    end
  end

  # get the list of customer concerns, diagnostics_steps and job_items
  api :GET, '/jobs/:id/job_all_items'
  error code: 400, desc: I18n.t('api.docs.resources.common.errors.bad_request')

  # def get_customer_concerns_diagnostics_and_job_items
  def job_all_items
  end

  def job_items_list
  end

  def single_job_item
    render template: 'api/v1/jobs/job_all_items.json.jbuilder'
  end

  # reorder customer concerns, diagnostics_steps and job_items
  api :GET, '/jobs/:id/reordering_concern_diagnostics_and_operations'
  error code: 400, desc: I18n.t('api.docs.resources.common.errors.bad_request')

  def reordering_concern_diagnostics_and_operations
    if params[:item] && params[:changeable_item]
      item_id = params[:item][:id]
      item_type = params[:item][:type]
      changeable_item_id = params[:changeable_item][:id]
      changeable_item_type = params[:changeable_item][:type]

      # get item data
      if item_type == 'customer_concern'
        first_item = @job.customer_concerns.find(item_id)
      elsif item_type == 'diagnostic_step_instance'
        first_item = @job.diagnostic_step_instances.find(item_id)
      elsif item_type == 'job_item'
        first_item = @job.job_items.find(item_id)
      end

      # get changeable_item data
      if changeable_item_type == 'customer_concern'
        second_item = @job.customer_concerns.find(changeable_item_id)
      elsif changeable_item_type == 'diagnostic_step_instance'
        second_item = @job.diagnostic_step_instances.find(changeable_item_id)
      elsif changeable_item_type == 'job_item'
        second_item = @job.job_items.find(changeable_item_id)
      end

      item_position = first_item.position
      first_item.update(position: second_item.position)
      second_item.update(position: item_position)

      render json: {status: :success}
    else
      render(json: {errors: @job.errors.messages}, status: :bad_request) && return
    end
  end

  # add previous declined operations
  def add_previous_declined_operation
    previous_job_item = JobItem.find_by_id(params[:previous_job_item_id])

    techs = Technician.where(id: previous_job_item.technicians, active: true).includes(user: [:user_additional_shops]).where(user_additional_shops: {repair_shop_id: @job.repair_shop_id}).pluck(:id)
    # create job_item for current job from previous job_item
    new_job_item = @job.job_items.create(
      previous_job_item.dup.attributes.merge(
        'previous_job_item_id' => previous_job_item.id,
        'state' => 'initial',
        'operation_id' => previous_job_item.operation_id,
        'customer_concern_id' => nil,
        'diagnostic_step_instance_id' => nil,
        'is_diagnostic_step' => false,
        'technician_diagnostic_id' => nil,
        technicians: techs,
        partstech_id: nil,
        partstech_session_id: nil,
        partstech_url: nil
      )
    )

    # recreate estimate_items from previous job_items
    new_job_item.previous_job_item&.estimate_items&.each do |estimate_item|
      new_ei = new_job_item.estimate_items.create(
        estimate_item.dup.attributes.merge(estimate_id: @job.estimate&.id)
      )
      if estimate_item.item_type == 'part' && estimate_item.part_detail
        if estimate_item.saved_through == 'PartsTech'
          new_ei.old_part_detail_id = estimate_item.part_detail.id
          new_ei.part_detail = nil
          new_ei.saved_through = nil
        else
          new_part_detail = estimate_item.part_detail.dup
          new_part_detail&.update(estimate_item_id: new_ei.id)
          new_ei.part_detail = new_part_detail
        end
        new_ei.save
      end
    end

    if new_job_item
      render json: {status: :success}
    else
      render(json: {errors: @job.errors.messages}, status: :bad_request) && return
    end
  end

  api :GET, '/jobs/:id/job_photos', I18n.t('api.docs.resources.jobs.job_photos.short_desc')
  error code: 400, desc: I18n.t('api.docs.resources.common.errors.bad_request')
  description I18n.t('api.docs.resources.jobs.job_photos.full_desc')

  def job_photos
    @job_photos = @job.job_photos
  end

  api :POST, '/:repair_shop_id/jobs/:id/add_job_item', I18n.t('api.docs.resources.jobs.add_job_item.short_desc')
  param :customer_states, :string, required: false
  param :customer_description, :string, required: false
  param :job_code, :string, required: false
  error code: 400, desc: I18n.t('api.docs.resources.common.errors.bad_request')
  description I18n.t('api.docs.resources.jobs.add_job_item.full_desc')

  def add_job_item
      Estimate.create(job: @job) if @job.estimate.blank?
      @job.coupons << Coupon.find(params[:coupon_ids]) if params[:coupon_ids]
      @item = @job.add_remove_job_items params[:job_items] if params[:job_items]
      if params[:lube_operation]
        @job.estimate.update(approval_time: Time.now)
        @job.job_items.each do |item|
          item.update(approved_by: 'other', approval_type: "other", approval_time: Time.zone.now, state: 'start_repair')
        end
      end
      @job.update(state: params[:state], approval_status: nil, approval_time: nil)
      @job.estimate.check_for_reapproval
      render(json: { success: 'add job item successfully',job_items: @item }, status: :ok)
      rescue Rack::Timeout::RequestTimeoutException => e
      render(json: { message: e.message }, status: 408)
  end

  api :POST, '/jobs/:id/add_job_photos', I18n.t('api.docs.resources.jobs.add_job_photos.short_desc')
  param :description, :string, required: false
  param :s3_url, :string, required: false
  param :cdn_url, :string, required: false
  param :job_item_id, :number, required: false
  param :job_id, :number, required: false
  error code: 400, desc: I18n.t('api.docs.resources.common.errors.bad_request')
  description I18n.t('api.docs.resources.jobs.add_job_photos.full_desc')

  def add_job_photos
    if @job_photo = JobPhoto.create(job_photo_params)
      @job_photo.send_text if params[:send_text]
    else
      render json: { errors: 'There is some problem on creating photo' }
    end
  end

  api :POST, '/:repair_shop_id/jobs/:id/add_payment', I18n.t('api.docs.resources.jobs.add_payment.short_desc')
  error code: 400, desc: I18n.t('api.docs.resources.common.errors.bad_request')
  description I18n.t('api.docs.resources.jobs.add_payment.full_desc')

  def add_payment
    card = params[:payment][:card]
    if params[:payment][:payment_option] == 'Card'
        unless (card = @job.customer.payment_profiles.create(payment_profile_params)).persisted?
          render(json: { errors: 'Errors while saving card details' }, status: :payment_required) && return
        end
    end
    payment = Payment.create(payment_params(card).merge(user_name: current_user.name))

    if @repair_shop.qbo_account&.access_token&.present?
      Integrations::QuickbooksOnline::SendPaymentWorker.perform_async(@repair_shop.id, payment.id)
    end

    if payment
      terminal = @repair_shop.terminal
      if terminal.present? && params[:payment][:payment_option] == 'Card'
        velox = Payments::Velox.new
        @response = velox.run_transaction2(terminal, payment.id, params[:payment][:payment_amount])
        render(json: { status: @response }, status: :payment_required) && return
      end

      render(json: { notice: 'Payment successfully done' }, status: :ok) && return
    else
      payment_not_completed_and_return
    end
  end

  def delete_payment
    payment = Payment.find(params[:payment_id])
    payment.destroy
    render(json: { notice: 'Deleted Payment successfully' }, status: :ok) and return
  end

  api :POST, '/:repair_shop_id/jobs/:id/close_job', I18n.t('api.docs.resources.jobs.add_payment.short_desc')
  error code: 400, desc: I18n.t('api.docs.resources.common.errors.bad_request')
  description I18n.t('api.docs.resources.jobs.add_payment.full_desc')

  def close_job
    @job.close_job
    render(json: { notice: 'Job closed' }, status: :ok) && return
  end

  api :POST, '/:repair_shop_id/jobs/:id/get_taxes', I18n.t('api.docs.resources.jobs.add_payment.short_desc')
  error code: 400, desc: I18n.t('api.docs.resources.common.errors.bad_request')
  description I18n.t('api.docs.resources.jobs.add_payment.full_desc')

  def get_taxes; end

  def send_nps_fedback_email
    if @job.present? &&  @repair_shop.option_enabled?('communications') && @job&.customer&.contact_preference == 'Email'
      NpsMailer.send_email(@job&.customer,@job.repair_shop_id,@repair_shop).deliver_now
    end
  end
  
  def send_estimate_text
    if @job.present?
      pdf_send_data 'estimate'
      @job.send_estimate_text @f_items
      render(json: { notice: 'Text was sent successfully', code: 200 }, status: :ok) && return
    else
      render(json: { error: 'Error - text message failed to send.', success: false }, status: 422) && return
    end
  end

  def send_estimate_email
    if @job.present? && @job.estimate.present?
      es = @job.estimate
      pdf_send_data 'estimate'
      res =  s3_url 'estimate',  @f_items, es
      CustomerMailer.send_estimate(@job.customer, res.s3_url, @job.repair_shop, @job).deliver_now
      render(json: { notice: 'The email was sent successfully.', success: true }, status: :ok) && return
    else
      render(json: { error: 'Error - the email failed to send.', success: false }, status: 422) && return
    end
  end

  def send_estimate_pdf
    if @job && @job.estimate.present?
      es = @job.estimate
      pdf_send_data 'estimate'
      res =  s3_url 'estimate',  @f_items, es
      render(json: res.to_json, status: :ok) && return
    else
      render(json: { error: 'error pdf not send' }, status: 422) && return
    end
  end

  api :PATCH, '/jobs/:id/update_vin', I18n.t('api.docs.resources.jobs.update_vin.short_desc')
  error code: 400, desc: I18n.t('api.docs.resources.common.errors.bad_request')
  description I18n.t('api.docs.resources.jobs.update_vin.full_desc')


  def update_vin
    if @job.vehicle.update(vin: params[:vin_no])
      render json: { notice: 'Vin was successfully updated.' }
    else
      render json: { errors: 'Invalid Vin number.' }
    end
  end

  def verify_vin
    verify Vehicle.verify_vin params[:vin_no], @job.vehicle
  end

  def qa_checklist_job_items
    @job_items = @job.job_items
    @job_items = @job_items.where("'?' = ANY(technicians)", current_user.technician_id) if current_user.technician?
  end

  private

  def s3_url(type, data, model_data)
    CreateAndSendPdf.perform_now(data, @job, type, model_data)
  end

  def set_job_crs
    if params[:customer_details].present? && params[:customer_details][:id].present?
      customer = Customer.find(params[:customer_details][:id])
      @job.customers_repair_shop = @repair_shop.customers_repair_shops.find_or_create_by(customer: customer)
    elsif params[:customers_repair_shop_id].present?
      crs = CustomersRepairShop.find(params[:customers_repair_shop_id])
      customer = crs.customer
      @crs = @repair_shop.customers_repair_shops.find_or_create_by(customer: customer)
      @job.customers_repair_shop = @crs
    elsif params[:customer_attributes].present?
      @crs = @repair_shop.customers_repair_shops.new(customer_create_params)
      if @crs.save
        @job.customers_repair_shop = @crs
        @repair_shop&.chain.customers_repair_shops.find_or_create_by(customer: @crs.customer) if @repair_shop.chain.present?
      else
        render(json: { errors: @crs.errors }, status: :bad_request) && return
      end
    end
  end

  def set_crs
    @crs = @job.customers_repair_shop
    @customer = @crs.customer
  end

  def find_job
    set_repair_shop
    @job = @repair_shop.jobs.include_show.where(job_number: Util.id_parser(params[:id])).first
    @job = @repair_shop.jobs.include_show.where(id: params[:id]).first if @job.nil?
    render(json: { errors: 'Invalid job' }, status: :not_found) && return if @job.blank?
  end

  def find_job_record
    @job = Job.includes(:job_items, :customer_concerns, coupons_jobs: [coupon: [:repair_shop]]).find(params[:id])
    render(json: { errors: 'Invalid job' }, status: :not_found) && return if @job.blank?
  end

  def set_job_items
    @final_items = []
    @final_items += @job.customer_concerns
    @final_items += @job.diagnostic_step_instances.where(customer_concern_id: nil).includes(:technician_diagnostics, :inspection)
    @final_items += if is_user_technician? && params[:lube].blank?
                      if params[:jobItemId]
                        @job.job_items.where(id: params[:jobItemId]).for_technicians(current_user.technician_id)
                      else
                        @job.job_items.for_technicians(current_user.technician_id)
                      end
                    elsif params[:jobItemId]
                      @job.job_items.where(id: params[:jobItemId]).load_associate
                    else
                      @job.job_items.load_associate
                    end
    @final_items.sort_by! { |obj| obj.position || 0 } if @final_items.any?
    @out_of_stock_op = @job.check_inventory_available_quantity if params[:lube].present?
    @removed_dignostic_notes = @job.technician_diagnostics.where(diagnostic_step_instance_id: nil).reorder("created_at ASC")
  end

  def job_create_params
    params.permit(:id, :description, :profit_center_id, :expected_by, :estimated_repair_time, :dont_text, :on_site, :comeback, :coupon_ids, :inspection_requested, :service_advisor_id,
                  :vehicle_id, :state_event, :technician_id, :po_number, :mileage_in, :mileage_out, :repair_shop_id, :source, :phone_type, :created_by,
                  :priority, :contact_preference, :driver_id, :reassign_customer, :customer_id, :reassign_customer, :is_estimate, qa_checklist: [],
                  vehicle_attributes: [:id,:vin, :make, :car_model, :year, :mileage, :last_repair_date, :customer_id,
                                       :license_plate, :state, :motor_vehicle_data, :unit_id, :vcdb_base_vehicle_id, :vcdb_vehicle_id, :previous_viscosity, :oil_capacity, :skip_cust_valid],
                  technician_attributes: %i[id name repair_shop_id],
                  job_items_attributes: [:id, :customer_states, :customer_description, :job_code, :approval_type, :operation_id, :partstech_id,
                                         estimate_items_attributes: %i[part_num part_terminology_id use_catalog
                                                                       quick_desc item_type is_labor quantity price_per_unit estimate_id id _destroy]])
  end

  def job_update_params
    params.permit(:expected_by, :technician_id, :profit_center_id, :service_advisor_id, :state_event, :source, :contact_preference, :phone_type, :vehicle_id,
                  :priority, :on_site, :coupon_ids, :po_number, :mileage_in, :mileage_out, :state_closed, :driver_id, :is_estimate, qa_checklist: [],
                  technician_attributes: %i[id name user_id repair_shop_id],
                  vehicle_attributes: [:id, :vin, :make, :car_model, :license_plate, :state, :year, :mileage, :last_repair_date, :customer_id, :motor_vehicle_data, :oil_capacity,
                                       :vcdb_sub_model_id, :vcdb_engine_config_id, :vcdb_style_config_id, :unit_id, :vcdb_base_vehicle_id, :vcdb_vehicle_id, :previous_viscosity, :skip_cust_valid])
  end

  def customer_update_params
    params.require(:vehicle_attributes).permit(customer_attributes: %i[first_name last_name email phone address city state zip_code country home_phone work_phone contact_preference])
  end

  def customer_create_params
    params.permit(customer_attributes: %i[first_name last_name email phone address city state zip_code country home_phone work_phone contact_preference])
  end

  def job_photo_params
    params.permit(:job_id, :job_item_id, :description, :s3_url, :cdn_url)
  end

  def payment_profile_params
    params.require(:payment_profile).permit(:authorization, :card_type,:card_name, :account_id)
  end

  def can_update_job?
    authorize @job, :update?
  end

  def authorized_user
    authorize @job
  end

  def authorized_technician
    authorize @job, :valid_technician?
  end

  def valid_technician?
    authorize @job, :valid_technician? if current_user.technician
  end

  def payment_not_completed_and_return
    render(json: { errors: 'Payment not done' }, status: :payment_required) && return
  end

  def render_vehicle_error
    render(json: { errors: "An open RO of this repair type already exists for this vehicle",
                   job_number: @existing_job.job_number,
                   same_repair_shop: @existing_job.repair_shop.id == params[:repair_shop_id].to_i,
                   repair_shop: @existing_job.repair_shop },
           status: :bad_request) && return
  end

  def render_another_customer_error
    render(json: { errors: "Vehicle belongs to another customer", customer_id: @existing_vehicle.customer_id, vehicle_id: @existing_vehicle.id, fleet_id: @existing_vehicle&.customer&.fleet_id }, status: :bad_request) && return
  end

  def parse_profit_center_id
    if params[:profit_center_id].is_a?(String)
      params[:profit_center_id] = params[:profit_center_id].to_i
    end
    if params[:profit_center_id].is_a?(Integer)
      if params[:profit_center_id].zero?
        params[:profit_center_id] = nil
      end
    end
  end

  def vehicle_exists_in_db?
    if params[:vehicle_attributes] && (params[:vehicle_attributes][:vin].present? || params[:vehicle_attributes][:license_plate].present?)
      existing_vehicle = Vehicle.where(vin: params[:vehicle_attributes][:vin]).first if params[:vehicle_attributes][:vin].present?
      existing_vehicle = Vehicle.where(state: params[:vehicle_attributes][:state],license_plate: params[:vehicle_attributes][:license_plate]).first if params[:vehicle_attributes][:license_plate].present? && params[:vehicle_attributes][:vin].blank?
      if existing_vehicle
        @existing_vehicle = existing_vehicle
        true
      else
        @existing_vehicle = nil
        false
      end
    end
  end

  def payment_params(card)
    {
      payment_amount: params[:payment][:payment_amount].to_f,
      payment_option: params[:payment][:payment_option],
      account_id: params[:payment][:account_id],
      payment_profile_id: card.try(:id),
      check_no: params[:payment][:check_no],
      owner_name: params[:payment][:owner_name],
      memo: params[:payment][:memo],
      authorization: params[:payment][:authorization],
      deposit_type: params[:payment][:deposit_type],
      ar_type: params[:payment][:ar_type],
      funding_source: params[:payment][:funding_source],
      customer_id: params[:payment][:customer_id],
      repair_shop_id: @repair_shop&.id,
      job_id: @job.id
    }
  end

  def customer_vehicle?(existing_vehicle)
    (params[:customer_details][:id] == existing_vehicle[:customer_id]) || (params[:customer_details][:phone] ==
      existing_vehicle&.customer&.phone)
  end

  def verify(message)
    render json: { notice: message }, status: 200
  end

  def existing_job_in_db?(id)
    chain_shop_ids = RepairShop.find(params[:repair_shop_id]).chain&.repair_shops&.pluck(:id)
    if id
      @existing_job = Job.where(vehicle_id: id,
                                warranty_or_policy: params[:warranty_or_policy],
                                repair_shop_id: chain_shop_ids || params[:repair_shop_id]).state_open_ros.order('created_at desc').first
      return true if @existing_job
    end
    false
  end

  def pdf_send_data(_type)
    @f_items = []
    customer_concerns = @job.customer_concerns
    diagnostic_step_instances = @job.diagnostic_step_instances.where(customer_concern_id: nil)
    job_items = @job.job_items.where(customer_concern: nil, diagnostic_step_instance: nil)

    @f_items = customer_concerns + diagnostic_step_instances + job_items

    @f_items = @f_items.sort_by { |obj| obj.position || 0 } if @f_items.any?
  end

  def get_vcdb_base_vehicle
    # @TODO: this checks to see if table exists to fix tests failures. Clean up after Rails 6.
    @vcdb_base_vehicle = @job&.vehicle&.vcdb_base_vehicle if CatalogsRecord.connection.table_exists? 'base_vehicle'
  end
end
