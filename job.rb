# frozen_string_literal: true

class Job < ApplicationRecord
  include Util
  has_paper_trail
  acts_as_sequenced scope: :repair_shop_id, column: :job_number
  include Messagable
  include RoundToCents
  include Totals
  include KeenData
  include UpdateWebhook
  include ReportHash
  include ActionView::Helpers::DateHelper
  include EmbedImage
  include ProcessFluids
  include DateFilter
  include PgSearch::Model

  attr_accessor :skip_aff, :customer_id, :reassign_customer, :destroying, :skip_status_callbacks

  GREEN_TIME_LIMIT = 3.hours
  YELLOW_TIME_LIMIT = 8.hours

  before_create do
    self.state_changed_at = Time.zone.now
    self.total_position = 0
    self.tax_exempt = true if customer && customer.find_crs(repair_shop_id).tax_exemption_id?
    update_sf_status
    # sequential_custom_id #can be used instead of including Util and acts_as_sequenced
  end
  before_create :set_tax_rate

  before_destroy :unlink_lyfts

  after_create :set_active_job_to_customer, unless: :skip_aff
  after_create :create_inspections
  after_save :set_vehicle_customer
  # after_create :copy_items_from_previous_job, unless: :skip_aff
  after_commit :update_webhooks, on: :update, unless: :skip_aff
  before_update :set_created_at, if: :will_save_change_to_is_estimate?
  before_save :update_sf_status, if: -> { will_save_change_to_state? || will_save_change_to_approval_status? }
  before_save :update_static_fields
  before_update :prevent_mileage_out_change, if: -> { self.mileage_out.present? }
  before_update :prevent_finalized_state_change, if: -> { will_save_change_to_state? && state_in_database == 'finalized' }
  after_initialize :update_customer_static, if: proc { |j| j.customer_name.nil? }
  after_create :update_vehicle_static, if: :new_vehicle
  after_update :set_inventory_available_quantity, if: -> { saved_change_to_is_estimate? && !self.is_estimate? }
  after_update :update_po, if: -> { saved_change_to_state_closed? && self.state_closed.present? }
  after_create :update_for_vehicle_estimates, if: -> { !self.is_estimate? }
  after_update :update_for_vehicle_estimates, if: -> { saved_change_to_is_estimate? && !self.is_estimate? }
  after_update :set_work_timestamps, if: :saved_change_to_state
  after_update :update_appointment, if: -> { (saved_change_to_technician_id? || saved_change_to_service_advisor_id?) && self.appointment.present? }
  after_update :sync_qbo_invoices, if: -> { saved_change_to_state_closed? && self.state_closed.present? && (repair_shop.option_enabled? 'quickbooks_sync') }
  after_update :update_contact_preference, unless: -> { self.contact_preference.present? }
  before_save :set_status, if: -> { !skip_status_callbacks && (will_save_change_to_state? || will_save_change_to_approval_status?) }

  has_one :invoice
  belongs_to :repair_shop, inverse_of: :jobs
  belongs_to :vehicle, inverse_of: :jobs
  belongs_to :driver, inverse_of: :jobs, optional: true
  belongs_to :appointment, optional: true
  belongs_to :profit_center, optional: true
  belongs_to :technician, inverse_of: :jobs, optional: true
  belongs_to :service_advisor, inverse_of: :jobs, optional: true
  belongs_to :customers_repair_shop, inverse_of: :jobs
  has_one :customer, through: :customers_repair_shop

  accepts_nested_attributes_for :technician

  accepts_nested_attributes_for :vehicle
  has_many :refunds, dependent: :destroy
  has_one :fleet, through: :customer
  has_one :vehicle_sub_model, through: :vehicle
  has_one :checklist, dependent: :destroy
  has_one :payment, -> { order created_at: :desc }, class_name: 'Payment', dependent: :nullify
  has_one :report, dependent: :nullify
  has_one :estimate, dependent: :destroy
  has_many :inspections, dependent: :destroy
  has_many :job_items, dependent: :destroy
  has_many :diagnostic_step_instances, dependent: :destroy
  accepts_nested_attributes_for :job_items, allow_destroy: true
  has_many :estimate_items, through: :job_items
  accepts_nested_attributes_for :estimate_items
  has_many :returns, through: :estimate_items
  has_many :labor_items, through: :job_items
  has_many :labor_details, through: :labor_items
  has_many :job_photos, through: :job_items
  has_many :job_photos, dependent: :destroy
  has_many :messages, dependent: :destroy
  has_many :messages_ordered_by_created, -> { order('created_at ASC') }, class_name: 'Message', dependent: :destroy
  has_many :notes, as: :noteable, dependent: :destroy
  has_many :notifications, as: :notify_subject, dependent: :destroy
  has_many :defective_operations, dependent: :destroy

  has_many :coupons_jobs, dependent: :destroy
  has_many :coupons, through: :coupons_jobs
  has_many :surveys, dependent: :destroy
  has_many :lyfts, dependent: :nullify
  has_many :lyfts_ordered_by_created, -> { order('created_at ASC') }, class_name: 'Lyft', dependent: :nullify
  has_many :stripe_charges, dependent: :nullify
  has_many :payments, dependent: :destroy
  has_many :payment_jobs, dependent: :destroy
  has_many :job_coupon_payments, dependent: :destroy

  has_many :customer_concerns, -> { order('created_at ASC') }, dependent: :destroy
  has_many :technician_diagnostics, -> { order('created_at ASC') }, dependent: :destroy
  has_many :solo_diagnostics, -> { where(customer_concern_id: nil).order('created_at ASC') }, class_name: 'TechnicianDiagnostic'
  has_many :diag_step_instances, -> { order('position ASC') }, dependent:  :destroy, class_name: "DiagnosticStepInstance"

  has_many :accounts, through: :payments
  has_many :purchase_orders, through: :job_items

  has_many :finalized_job_items, -> { where(state: 'finalize') }, class_name: 'JobItem'

  delegate :service_reminders, to: :vehicle
  delegate :name, to: :repair_shop, prefix: true
  delegate :appointments, to: :customer
  delegate :phone, to: :customer, prefix: true
  delegate :email, to: :customer, prefix: true
  delegate :phone_sanitized, to: :customer, prefix: true
  delegate :vin, to: :vehicle, prefix: true
  delegate :car_model, to: :vehicle, prefix: true
  delegate :make, to: :vehicle, prefix: true
  delegate :year, to: :vehicle, prefix: true
  delegate :price, to: :vehicle, prefix: true
  delegate :mileage, to: :vehicle, prefix: true

  validates :vehicle, presence: true
  validates :mileage_in, length: { maximum: 7 }
  validates :mileage_out, length: { maximum: 7 }
  validates :job_number, uniqueness: { scope: :repair_shop_id }

  attr_accessor :mileage
  attr_accessor :new_vehicle

  scope :state_closed_ros, -> { where(state_closed: true, is_estimate: false, is_refund: false) }
  scope :state_finalized_ros, -> { where(state: 'finalized', is_estimate: false, is_refund: false) }
  scope :state_open_ros, -> { where(state_closed: false, is_archived: false, is_estimate: false, is_refund: false) }
  scope :filtered_ros, -> { where(is_refund: false) }
  scope :is_archived_ros, -> { where(is_archived: true) }
  scope :is_estimate_ros, -> { where(is_estimate: true) }
  scope :by_shop, -> (id) { where(repair_shop_id: id) }
  scope :get_estimate_ros_by_status, -> (status) { where(is_estimate: true, sf_status: status) }
  scope :get_ros_by_status, -> (status) { where(sf_status: status, is_estimate: false) }

  pg_search_scope :filter_by_tech_and_advisor, lambda { |filter_type, query|
    raise ArgumentError unless [:technician_id, :service_advisor_id].include?(filter_type)
    {
      against: filter_type,
      query: query,
      using: {
        tsearch: {dictionary: "simple"}
      }
    }
  }

  enum source: {
    "Advertisement": 1,
    "Walk-in": 2,
    "Employee": 3,
    "Google": 4,
    "Fleet": 5,
    "Warranty": 6,
    "Referral": 7,
    "Repeat Customer": 8,
    "Telephone": 9,
    "Website": 10,
    "Extended Warranty": 11
  }

  enum priority: {
    "Customer Waiting": 1,
    "High Priority": 2,
    "Medium Priority": 3,
    "Low Priority": 4
  }

  enum contact_preference: {
    "Text": 1,
    "Phone": 2,
    "Email": 3,
    "See Notes": 4
  }

  enum approval_status: {
    "partial": 1,
    "approved": 2,
    "deferred": 3,
    "mixed": 4
  }

  enum phone_type: {
    "Mobile": 1,
    "Home": 2,
    "Work": 3
  }

  # Special statuses for service first

  enum sf_status: {
    "Diagnosing": 1,
    "Waiting on Customer": 2,
    "Waiting on Parts": 3,
    "In Process": 4,
    "Finished": 5,
    "Appointment": 6,
    "On-Hold": 7,
    "Completed": 8,
    "Finalized": 9,
    "Closed": 10
  }

  enum inspection_status: {:incomplete => 0, :completed => 1, :sent => 2}

  # Method for special statuses for service first

  def update_sf_status
    unless sf_flag_enabled
      status = case self.state
        when 'work_completed', 'repair_completed', 'finalized'
          5
        when 'work_started', 'repair_in_progress'
          4
        when 'parts_delayed', 'parts_ordered'
          3
        when 'diagnostic_complete'
          2
        else
          if self.approval_status == 'approved' || self.approval_status == 'mixed'
            3
          elsif self.approval_status == 'deferred' || self.state == 'repair_denied'
            5
          elsif profit_center_name == 'lube'
            4
          else
            1
          end
        end
      self.sf_status = status
    end
  end

  def set_status(save_status = false)
    if sf_flag_enabled
      in_progress_items = self.job_items.where(state: 'start_repair')
      pending_items = self.job_items.where(state: 'initial')
      ordered_parts = pending_items.where.not(approval_type: [nil, '']).map(&:ordered_parts).flatten.compact
      all_states = ["declined", "start_repair", "complete_repair"]
      state = self.state
      if !id || job_items.count == 0
        state = 'awaiting_diagnostic'
      elsif self.state == 'finalized'
        state = self.state
      elsif in_progress_items.any?
        state = 'repair_in_progress'
      elsif ordered_parts.any?
        state = unordered_parts.any? ? 'parts_delayed' : 'parts_ordered'
      elsif (job_items.count.zero? || pending_items.count.zero?) && state != 'awaiting_diagnostic'
        # Need to confirm, if this condition block should be removed or not
        # state = 'repair_completed'
      elsif (job_items.pluck(:state).uniq - all_states).empty?
        state = 'repair_completed'
      elsif state != 'awaiting_diagnostic'
        state = 'repair_in_progress'
      end
      self.state = state
      self.sf_status = set_custom_status
      self.skip_status_callbacks = true
      self.save if save_status
    end
  end

  def set_custom_status
    status = case self.state
    when 'finalized'
      self.state_closed ? 10 : 9
    when 'work_completed', 'repair_completed', 'repair_denied'
      8
    when 'work_started', 'repair_in_progress'
      4
    when 'parts_delayed', 'parts_ordered'
      3
    when 'diagnostic_complete'
      2
             else
      if self.approval_status == 'approved' || self.approval_status == 'mixed'
        self.sf_status
      elsif self.approval_status == 'deferred' || self.state == 'repair_denied'
        5
      else
        1
      end
    end
    status
  end

  def self.account_unpaid_ros(acct_id, shop_id)
    ros = []

    Payment.includes(:job).where(account_id: acct_id, repair_shop_id: shop_id).where.not(job_id: nil).each do |p|
      next unless p.job.state_closed?

      if (ro = ros.find { |ro| ro[:id] == p.job_id })
        ro[:remaining_balance] += p.payment_amount
      else
        ros << {
          id: p.job_id,
          job_number: p.job.job_number,
          remaining_balance: p.payment_amount
        }
      end
    end

    Payment.includes(:payment_jobs).where(account_id: acct_id, repair_shop_id: shop_id).where(job_id: nil).collect(&:payment_jobs).flatten.each do |pj|
      if (ro = ros.find { |ro| ro[:id] == pj.job_id })
        ro[:remaining_balance] = (ro[:remaining_balance] - pj.payment_amount).round(2)
      end
    end

    ros
  end

  def prevent_finalized_state_change
    self.state = 'finalized'
  end

  def prevent_mileage_out_change
    self.mileage_out = mileage_out
  end

  def set_state_changed_at
    self.state_changed_at = Time.zone.now
  end

  state_machine initial: :awaiting_diagnostic do
    before_transition do |job, transition|
      job.state = transition.to_name
      job.update_sf_status
      job.set_state_changed_at
    end

    # after_transition on: :start_diagnostic, do: :send_greetings_text
    after_transition on: :end_diagnostic, do: :send_end_diagnostic_text
    after_transition on: :delay_parts, do: :send_delayed_parts_text
    after_transition on: :order_parts, do: :send_parts_ordered_text
    after_transition on: :receive_parts, do: :send_parts_delivered_text
    after_transition on: :start_repair, do: :send_repair_in_progress_text
    after_transition on: :finalize, do: %i[set_finalized_at finalize_job_items send_repair_completed_text update_inventory_quantity_val send_finalized_invoice]
    before_transition on: :deny_repair, do: :set_denied_status
    # around_transition  do |job, transition, block|
    #   job.job_items.each do |job_item|
    #     job_item.update(:state_changed_at => Time.zone.now)
    #   end
    #   # job.job_items.update.state_changed_at.save()
    # end

    event :start_diagnostic do
      transition %i[awaiting_diagnostic repair_denied repair_completed] => :technician_performing_diagnostic
    end

    event :end_diagnostic do
      transition %i[technician_performing_diagnostic awaiting_diagnostic repair_completed repair_denied] => :diagnostic_complete
      # Contact car owner
    end

    event :order_parts do
      transition %i[technician_performing_diagnostic awaiting_diagnostic diagnostic_complete repair_completed repair_denied] => :parts_ordered
    end

    event :delay_parts do
      transition %i[technician_performing_diagnostic awaiting_diagnostic diagnostic_complete parts_ordered repair_completed repair_denied] => :parts_delayed
      # Contact car owner
    end

    event :receive_parts do
      transition %i[technician_performing_diagnostic awaiting_diagnostic diagnostic_complete parts_ordered parts_delayed repair_completed repair_denied] => :parts_delivered
    end

    event :start_repair do
      transition %i[technician_performing_diagnostic awaiting_diagnostic diagnostic_complete parts_ordered parts_delayed parts_delivered repair_completed repair_denied] => :repair_in_progress
    end

    event :complete_repair do
      transition %i[technician_performing_diagnostic awaiting_diagnostic diagnostic_complete parts_ordered parts_delayed parts_delivered repair_in_progress repair_denied] => :repair_completed
      # Contact car owner
    end

    event :finalize do
      transition %i[technician_performing_diagnostic awaiting_diagnostic diagnostic_complete parts_ordered
      parts_delayed parts_delivered repair_in_progress repair_completed repair_denied] => :finalized
    end

    event :deny_repair do
      transition %i[technician_performing_diagnostic awaiting_diagnostic diagnostic_complete parts_ordered parts_delayed parts_delivered repair_in_progress] => :repair_denied
    end
  end

  scope :order_by_newest, -> { order('created_at DESC') }

  def car_service
    CarsApi.new(repair_shop_id)
  end

  def labor_estimate_items
    estimate_items.where(item_type: 'labor')
  end


  def job_number
    return "%04i" % repair_shop.custom_id.to_i + "%06i" % self.read_attribute(:job_number) if repair_shop.present? && repair_shop.custom_id && self.persisted?
    self.read_attribute(:job_number)
  end

  def self.search(query)
    jobs = if query[:open].present?
             query[:open] == 'true' ? Job.state_open : Job.state_closed_ros
           else
             self
    end

    final_query = []
    final_query.push("jobs.state = '#{query[:state]}'") if query[:state].present?
    final_query.push("vehicles.id = '#{query[:vehicle_id]}'") if query[:vehicle_id].present?
    final_query.push("lower(customers.name) like '#{query[:customer_name].downcase}'") if query[:customer_name].present?

    jobs.joins(:vehicle, :customer).where(final_query.join(' AND '))
  end

  def self.state_open
    # without_states(:repair_completed, :repair_denied)
    without_states(:repair_denied).includes(:payment).where(payments: { id: nil })
  end

  def check_job_closed
    state_closed?
  end


  def is_job_closed?
    state == 'finalized' || state == 'repair_denied'
  end

  def set_created_at
    self.created_at = Time.zone.now
  end

  def init_custom_id
    repair_shop_custom_id = repair_shop.custom_id
    if repair_shop_custom_id.present?
      last_id = repair_shop.jobs.where.not(custom_id: nil)
                           .order(:created_at)&.last&.custom_id
      last_id = if last_id.present?
        last_id[4..-1].to_i + 1
                else
        1
      end
      self.update(custom_id: repair_shop_custom_id + format('%06d', last_id % 1_000_000))
    end
  end

  def sequential_custom_id
    last_id = repair_shop.jobs.where.not(job_number: nil)
                         .order(:created_at)&.last&.read_attribute(:job_number)
    new_last_id = last_id.present? ? last_id + 1 : 1
    self.job_number = new_last_id
  end

  def state_changed_at_humanized
    state_changed_at.to_s(:long)
  end

  def state_color
    if (Time.now - GREEN_TIME_LIMIT) < state_changed_at && state_changed_at < Time.now
      'green'
    elsif (Time.now - YELLOW_TIME_LIMIT) < state_changed_at && state_changed_at < (Time.now - GREEN_TIME_LIMIT)
      'yellow'
    else
      'red'
    end
  end

  def unlink_lyfts
    lyfts&.each do |lyft|
      lyft.update(job_id: nil)
    end
  end

  # Find job by ro id
  # example 6012021835. shop cusotm id = 6012. job_number = 21835
  def self.by_number(full_number)
    last_id = full_number.length - 1
    RepairShop.find_by(custom_id: full_number[0..3])&.jobs.find_by(job_number: (full_number[4..last_id]).to_i)
  end

  def last_job_message
    messages_ordered_by_created.last.message if messages_ordered_by_created.present?
  end

  def estimate_not_approval
    estimate&.not_approved
  end

  # to get the list of a job's missing data
  def missing_info
    missing_data = []
    !expected_by ? missing_data << 'expected_by' : false
    !technician ? missing_data << 'technician_id' : false
    !vehicle.vin ? missing_data << 'vin' : false
    !customer.first_name.present? ? missing_data << 'first_name' : false
    !customer.last_name.present? ? missing_data << 'last_name' : false
    !customer.email ? missing_data << 'email' : false
    !customer.phone ? missing_data << 'phone' : false
    missing_data
  end

  # To update invoice & customer balance. And set text_active to true after job is closed.
  def update_invoice_customer(payment)
    # set_crs
    # @crs.update(balance: round_to_cents(@crs.balance.to_f - payment.payment_amount))
    # customer.update(balance: round_to_cents(customer.balance - payment.payment_amount))
  end

  def customer_payment
    UpdateJobWorker.perform_async(self.id, 'payment')
    Notification.create(notify_subject: self, notifiable: service_advisor&.user,
                        action: 'invoice_paid', notify_actor: customer)
  end

  # Set customers repair shop to update balance
  def set_crs
    @crs = customer.customers_repair_shops.where(customerable_id: repair_shop_id, customerable_type: 'RepairShop').first
  end

  # To set text_active to true when Job is created
  def set_active_job_to_customer
    # send greetings text if first job with shop
    unless customers_repair_shop&.jobs&.where(repair_shop: repair_shop)&.where&.not(id: self.id)&.any?
      send_greetings_text
    end
    customers_repair_shop.jobs.where(text_active: true, repair_shop_id: repair_shop_id).update_all(text_active: false)
    update(text_active: true)
  end

  # To set tax rates of job
  def set_tax_rate
    default_tax = repair_shop&.sales_tax.presence || 0
    self.part_tax_rate = repair_shop&.part_tax.presence || default_tax
    self.labor_tax_rate = repair_shop&.labor_tax.presence || 0
    self.sublet_tax_rate = repair_shop&.sublet_tax.presence || default_tax
    self.fluid_tax_rate = repair_shop&.fluid_tax.presence || default_tax
    self.tires_tax_rate = repair_shop&.tires_tax.presence || default_tax
    self.tow_tax_rate = repair_shop&.tow_tax.presence || default_tax
    self.supplies_tax_rate = repair_shop&.supplies_tax.presence || default_tax
    self.rental_tax_rate = repair_shop&.rental_tax.presence || default_tax
    self.fee_tax_rate = repair_shop&.fee_tax.presence || default_tax
    self.supplies_max = repair_shop&.supplies_max.presence
    self.supplies_percent = repair_shop&.supplies_percent.presence
  end

  # To create note if attributes of job is updated
  def create_note(params, id)
    jobs_name = []
    jobs_name << "Service Advisor- #{service_advisor.full_name}, " if versions.last.reify.service_advisor_id != service_advisor_id
    jobs_name << "Technician- #{technician.full_name}. " if versions.last.reify.technician_id != technician_id && technician.present?
    jobs_name << "Technician- " if versions.last.reify.technician_id != technician_id && technician.blank?
    content = 'Transferred to ' + jobs_name.join(' and ') + params[:content].to_s if jobs_name.present?
    content += 'Expected_by updated.' if versions.last.reify.expected_by != expected_by && content.present?
    content = 'Expected_by updated.' if versions.last.reify.expected_by != expected_by && content.nil?
    notes.create(content: content, user_id: id) if content.present?
  end


  def save_estimate(is_final = false)
    if is_final
      estimate.saved_time = Time.now
      estimate.save
    end
    update(state: 'diagnostic_complete', is_estimate: false)
    f_items =  pdf_send_data
    send_estimate_text f_items
  end

  def set_job_item_technician
    job_items.where(technicians: []).each do |job_item|
      job_item.update(technicians: [technician_id])
    end
  end

  # create job items & its estimate_items for job
  def create_job_item_estimate_items(job_items_params)
    update(state: 'technician_performing_diagnostic')
    job_items.each do |job_item|
      if job_item.operation && job_item.operation.line_items&.any?
        job_item.save_canned_job_line_item(estimate)
        job_item.save_labor_items_for_estimate
      else
        if job_items_params
          # create estimate-items from operation, if job-item from api operation
          j_item = job_items_params.find { |j_item| j_item[:partstech_id] == job_item.partstech_id }
          job_item.save_labor_item_info j_item[:labor_items] if j_item && j_item[:labor_items].present?
          create_estimate_items j_item[:estimate_items], job_item if j_item && j_item[:estimate_items].present?
        end
        estimate.estimate_items.create(job_item: job_item) if estimate.present? && (!job_items_params || !j_item[:estimate_items].present?)
      end
    end
  end

  # Called when create_estimate is called
  def add_remove_job_items(params_job_items, appt = false)
    items = []
    params_job_items.each do |job_item|
      transaction do
        if job_item['id'].nil?
          if appt
            job_item = ActionController::Parameters.new(job_item.select { |_k,v| v.present? })
          end
          @job_item = job_items.create job_item_params(job_item)
          # @job_item.save_canned_job_line_item estimate if @job_item.operation.present? && estimate && job_item['estimate_items'].blank?
          # if job-item is from api operation, create estimate_items for operation
          @job_item.save_labor_item_info job_item[:labor_items] if @job_item.partstech_id? && job_item[:labor_items] && estimate.present?

          if job_item['estimate_items'].present?
            self.estimate = @job_item&.job&.create_estimate if estimate.nil?
            veh_id = job_item['vcdb_base_veh_id']
            # Handle Oil Changes
            if job_item['operation_type'] == 'oil_change'
              estimate_items = job_item['estimate_items'] || []
              # Add oil filter part for oil change
              estimate_items << {
                item_type: 'part',
                quick_desc: "Engine Oil Filter",
                part_terminology_id: 5340,
                use_catalog: 'partstech',  # @Todo what we use when get data to motor api
                quantity: 1
              }
              # add oil fluids for oil change
              estimate_items += get_fluids(nil, vehicle, nil, true)
              if estimate_items.last[:unsure]
                @job_item.update(unclear_fitment: true)
                estimate_items.map do |ei|
                  ei.tap { |est| est.delete(:unsure) }
                end
              end
            # Handle MOTOR Override Operations
            elsif job_item['application_id'].present? && job_item['operation_type'] != "build"
              estimate_items = get_terminologies(veh_id, job_item['content_type'], job_item['estimate_items'],
                                                 job_item['quantity'], job_item['application_id'])
            # Handle Manual Operations
            else
              estimate_items = job_item['estimate_items']
            end
            create_estimate_items estimate_items, @job_item
          end
          @job_item.save_labor_items_for_estimate
          # estimate.estimate_items.create(job_item: @job_item) if estimate.present? and !job_item[:estimate_items].present?
        end
      end
      items.push(job_items_added)
    end
    update_sf_status
    return items
  end

  def job_items_added
    return {
      belongs_to_priced_step: @job_item&.diagnostic_step_instance&.diagnostic_step&.default_rate&.positive?,
      customer_concern_id: @job_item&.customer_concern_id,
      customer_description: @job_item&.customer_description,
      diagnostic_step_instance_id: @job_item&.diagnostic_step_instance_id,
      get_pretax_total: @job_item&.get_pretax_total,
      id: @job_item&.id,
      is_diagnostic_step: @job_item&.is_diagnostic_step,
      item_type: 'job_item',
      position: @job_item&.position,
      state: @job_item&.state,
      get_tax: @job_item&.get_tax,
      margin: @job_item&.margin,
      estimate_items: @job_item&.estimate_items
    }
  end
  # get terminology parts data using motor api

  def get_terminologies(veh_id, content_type, estimate_items, quantity, app_id)
    filtered_types = [5432, 49_606, 52_386, 16_412]
    response = CarsMotorApi.new.get_pcdb_parts(content_type, self.vehicle.vcdb_engine_config_id, self.vehicle.vcdb_sub_model_id, veh_id, app_id.to_i, self.vehicle.vin)
    if response.present?
      response.each do |val|
        position =  val[:Position]
        attributes = val[:Attributes]
        val = val[:PCDBPart]
        part_size = attributes.blank? ? nil : attributes[0]['Description']
        unless filtered_types.include? val['PartTerminologyID'].to_i
          # If a fluid comes back, get the fluid information
          if val['Category']['ID'] == 1
            ei = get_fluids app_id, self.vehicle, content_type
            if ei.any?
              estimate_items += ei
            else
              estimate_items << ({
                item_type: 'part',
                quick_desc: val['PartTerminologyName'],
                part_terminology_id: val['PartTerminologyID'].to_i,
                use_catalog: 'partstech',  # @Todo what we use when get data to motor api
                quantity: position[:quantity] || quantity,
                position: position[:name],
                pcdb_position_id: position[:pcdb_position_id],
                position_id: position[:position_id],
                part_size: part_size
              })
            end
          else
            estimate_items << ({
              item_type: 'part',
              quick_desc: val['PartTerminologyName'],
              part_terminology_id: val['PartTerminologyID'].to_i,
              use_catalog: 'partstech',  # @Todo what we use when get data to motor api
              quantity: position[:quantity] || quantity,
              position: position[:name],
              pcdb_position_id: position[:pcdb_position_id],
              position_id: position[:position_id],
              part_size: part_size
            })
          end
        end
      end
    end
    estimate_items
  end

  def derived_line_item_price(itm_cost, qty, package_details)
    quantity = qty || 0
    total_qty = package_details[:total_qty] || 1
    item_cost = itm_cost
    if package_details[:part_line_items_sum]&.zero?
      line_item_price = package_details[:parts_total] / total_qty if total_qty&.nonzero?
      line_item_price = package_details[:parts_total] if total_qty&.zero? || total_qty&.nil?
    else
      sum = (package_details[:part_line_items_sum] || 1).to_f
      total = package_details[:parts_total].to_f || 0
      line_item_price = item_cost / sum * total
    end
    line_item_price&.positive? ? line_item_price : 0
  end

  def get_package_details(job_item, params_estimate_items = [])
    package_details = {}
    params_estimate_items += EstimateItem.where(job_item_id: job_item.id)
    if job_item[:package_price].present?
      # part total
      part_line_items_sum = []
      labor_total = []
      labor_total = job_item[:labor_price].presence || []
      total_qty = 0
      params_estimate_items.each do |e_items|
        if e_items[:item_type] == "part" && !e_items[:additional]
          cost = e_items&.cost if e_items.is_a?(EstimateItem)
          cost ||= e_items.respond_to?(:cost) ? e_items[:cost] : e_items["cost"]
          cost = cost&.to_f
          quantity = e_items&.quantity if e_items.is_a?(EstimateItem)
          quantity ||= e_items.respond_to?(:quantity) ? e_items[:quantity] : e_items["quantity"]
          quantity = quantity&.to_f
          total_qty += (quantity || 0)
        end
        part_line_items_sum << quantity * cost if cost && quantity
        (labor_total << ((quantity || 0) * ((job_item.try(:job).try(:repair_shop)&.calculate_labor((quantity || 0))) || job_item.try(:job).try(:repair_shop).actual_labor_rate(vehicle) || 0))) if e_items[:item_type] == 'labor' && job_item[:labor_price].blank?
      end

      part_line_items_sum = part_line_items_sum.inject(:+)
      labor_total = labor_total.inject(:+) if job_item[:labor_price].blank?
      package_total = job_item[:package_price]
      parts_total = package_total.to_f - labor_total.to_f
      package_details = { part_line_items_sum: part_line_items_sum, parts_total: parts_total, total_qty: total_qty }
    end
  end

  # create estimate items from API operation if estimate for RO is present
  def create_estimate_items(params_estimate_items, job_item)
    package_details = get_package_details(job_item, params_estimate_items)
    labor_divisor = 0

    if job_item[:labor_price].present?
      labor_divisor = params_estimate_items.select { |i| i[:item_type] == 'labor' }.collect { |i| i["quantity"] || i[:labor_time] || i[:quantity] }.sum
    end

    params_estimate_items = filter_fluid(params_estimate_items, job_item.operation[:fluid_limit]) if job_item.operation&.try(:fluid_limit)
    params_estimate_items.each do |item|
      if item && item[:item_type] == 'part'
        if job_item[:package_price].blank? || (job_item[:package_price].present? && item[:cost] && item[:additional])
          price = item[:price_per_unit]&.to_f
          price ||= (self.try(:repair_shop)&.calculate_price(item[:cost].to_f) && self.repair_shop.calculate_price(item[:cost].to_f)[:total_price].to_f) if item[:cost] && item[:cost]&.to_f&.nonzero?
        elsif job_item[:package_price].present? && item[:cost] && !item[:additional]
          price = derived_line_item_price((item[:cost] || (self.try(:repair_shop)&.calculate_price(item[:cost].to_f) && self.repair_shop.calculate_price(item[:cost].to_f)[:total_price].to_f)), item[:quantity], package_details)
        end
        if item[:package_add].present? && job_item[:package_price].present? && !item[:additional]
          price += item[:package_add]&.to_f
        end
        source_price = item[:cost]&.to_f || (self.try(:repair_shop)&.calculate_price(item[:cost].to_f) && self.repair_shop.calculate_price(item[:cost].to_f)[:total_price].to_f)
        use_catalog = item[:part_terminology_id] ? 'partstech' : 'false'
        if item[:part_num].present?
          inventory_part = repair_shop.inventories.find_by(part_number: item[:part_num])
        end

        if inventory_part.present?
          part_details = {
            price: price || inventory_part[:part_price],
            core_price: inventory_part.core_price,
            manufacturer: inventory_part.part[:manufacturer],
            part_name: inventory_part[:part_description],
            package_add: inventory_part.package_add,
            part_number: inventory_part[:part_number],
            quantity: item[:quantity],
            cost: inventory_part[:cost],
            vendor_id: inventory_part[:vendor_id]
          }
        end

        if part_details.present?
          estimate.estimate_items.create(job_item: job_item, item_type: 'part', quantity: item[:quantity], package_add: part_details[:package_add],
                                        quick_desc: item[:quick_desc], part_terminology_id: item[:part_terminology_id],
                                        use_catalog: use_catalog, cost: item[:cost], price_per_unit: price, part_num: item[:part_num], additional: item[:additional],
                                        position: item[:position], pcdb_position_id: item[:pcdb_position_id], position_id: item[:position_id], part_size: item[:part_size],
                                        part_detail_attributes: part_details, notes: item[:notes], viscosity: item[:viscosity], saved_through: item[:saved_through], total_quantity: item[:quantity])
          inventory_part.update(available_quantity: inventory_part.available_quantity - item[:quantity]) unless estimate.job.is_estimate?
        else
          estimate.estimate_items.create(job_item: job_item, item_type: 'part', quantity: item[:quantity],
                                        quick_desc: item[:quick_desc], part_terminology_id: item[:part_terminology_id], additional: item[:additional],
                                        use_catalog: use_catalog, cost: item[:cost], price_per_unit: price, viscosity: item[:viscosity],
                                         position: item[:position], pcdb_position_id: item[:pcdb_position_id], position_id: item[:position_id], part_size: item[:part_size],
                                        part_num: item[:part_num], notes: item[:notes], saved_through: item[:saved_through])
        end
      elsif item && item[:item_type] == 'labor'
        cost = technician&.hourly_rate || repair_shop.default_hourly_rate
        price = job_item[:labor_price] / labor_divisor if job_item[:labor_price].present?
        price = item[:price_per_unit] || job_item.try(:job).try(:repair_shop)&.calculate_labor(item[:quantity] || item[:labor_time]) || repair_shop.actual_labor_rate(vehicle) if job_item[:labor_price].blank?
        quantity = item[:quantity] || item[:labor_time]

        labor_item = ''
        if item[:type] == 'base'
          labor_item = job_item.labor_items.find_by(labor_type: 'Base')
        elsif item[:type] == 'additional'
          labor_item = job_item.labor_items.find_by(labor_type: 'Additional')
        end
        estimate_item_attr = { job_item: job_item, item_type: 'labor', quantity: quantity, cost: cost, price_per_unit: price, quick_desc: item[:quick_desc] }
        estimate_item_attr[:labor_item] = labor_item #unless id?
        estimate.estimate_items.create(estimate_item_attr)

      end
    end
    params_estimate_items.each do |item|
      next unless item && item[:item_type] == 'fees'
      estimate_item_attr = { job_item: job_item, quick_desc: item[:quick_desc], item_type: 'fees', fee_amount: item[:fee_amount],
                              fee_percentage: item[:fee_percentage] }
      if item[:base_item_id]
        l_item = LineItem.find_by(id: item[:base_item_id])
        e_item = estimate.estimate_items.find_by(quick_desc: l_item.quick_desc, item_type: l_item.item_type, quantity: l_item.quantity) if l_item
        estimate_item_attr[:base_item_id] = e_item.id if e_item
      end
      estimate.estimate_items.create(estimate_item_attr)
    end
  end

  # create operation and line-items through API operations
  def create_operation_line_items(params_job_items = nil)
    return unless params_job_items.present?
    job_items.each do |job_item|
      j_item = params_job_items.find { |j_item| j_item[:partstech_id] == job_item.partstech_id }
      if j_item && j_item['estimate_items'] && !j_item['estimate_items'].empty?
        @operation = job_item.create_operation(name: j_item['customer_description'], description: j_item['customer_description'], partstech_id: j_item['partstech_id'], repair_shop_id: repair_shop_id) # create (api) operation for job_item
        j_item['estimate_items'].each do |item| # create line_items based on (api) operation
          if item['item_type'] == 'part'
            @operation.line_items.create(item_type: 'part', quick_desc: item['quick_desc'], part_terminology_id: item['part_terminology_id'])
          elsif item['item_type'] == 'labor'
            cost = technician&.hourly_rate || repair_shop.default_hourly_rate
            price = repair_shop.actual_labor_rate(vehicle)
            @operation.line_items.create(item_type: 'labor', quantity: item[:labor_time], quick_desc: item['quick_desc'], cost: cost, price_per_unit: price)
          end
        end
        job_item.update(operation_id: @operation.id)
      end
      job_item.save_labor_item_info j_item['labor_items'] if j_item && j_item['labor_items']
    end
  end

  def update_previous_inventory_quantity(line_item)
    old_part_detail = line_item.part_detail.last_part_detail
    unless self.is_estimate?
      inventory = Inventory.find_by(repair_shop_id: repair_shop_id, part_number: old_part_detail.part_number) if old_part_detail.part_number != line_item.part_num
      inventory&.update(available_quantity: inventory.available_quantity + old_part_detail.quantity) if inventory
    end
    line_item.part_detail.quantity || line_item.quantity
  end


  def save_draft_or_final_for_estimate(line_item)
    inventory = Inventory.find_by(repair_shop_id: repair_shop_id, part_number: line_item.part_num)
    if line_item.part_detail
      line_item_quantity = update_previous_inventory_quantity line_item
    elsif line_item.quantity
      line_item_quantity = line_item.quantity.to_f - line_item.try(:total_quantity).to_f
    else
      line_item_quantity = 0
    end
    quant = (inventory&.available_quantity&.to_f || 0) - (line_item_quantity&.to_f || 0) if inventory
    ##Check that Inventory exist, the job isn't an estimate and the job has been approved
    if inventory && !self.is_estimate? && !line_item.job_item.approval_type.nil?
      inventory.update(available_quantity: quant)
    end
    line_item.update(total_quantity: line_item.quantity.to_f)
  end

  def set_inventory_available_quantity
    job_items = self.job_items
    job_items.each do |ji|
      next unless ji.state != "declined"
      ji.estimate_items.each do |ei|
        if ei.saved_through == "Inventory" && ei.part_detail.present?
      save_draft_or_final_for_estimate ei
        end
      end
    end
  end

  # To save estimate as a draft
  def save_draft_estimate
    estimate_items.each do |estimate_item|
      save_draft_or_final_for_estimate estimate_item if Inventory.exists?(part_number: estimate_item.part_num) && estimate_item.quantity.to_f != estimate_item.total_quantity.to_f
    end
  end

  # Updating inventory quantity when removing from line item
  def update_inventory_quantity(ids, line_items)
    line_items.where(id: ids).each do |line_item|
      if Inventory.exists?(part_number: line_item.part_num, repair_shop_id: repair_shop_id)
        inventory = Inventory.find_by(repair_shop_id: repair_shop_id, part_number: line_item.part_num)
        quant = inventory.available_quantity.to_f + line_item.quantity.to_f
        inventory.update(available_quantity: quant)
      end
      line_item.destroy
    end
  end

  def finalize_job_items
    job_items.where.not(state: ['declined', 'finalize']).each do |ji|
      ji.skip_afc = true
      ji.update(state: 'finalize')
    end
  end

  def update_inventory_quantity_val
    job_items = self.job_items.where(state: "finalize")
    job_items.each do |item|
      item.estimate_items.each do |e_item|
        next unless e_item.saved_through == "Inventory"
        inventory = Inventory.find_by(repair_shop_id: repair_shop_id, part_number: e_item.part_detail&.part_number) if e_item.part_detail.present?
        if inventory.present?
          val = (inventory.quantity - e_item.part_detail.quantity).round(2)
          inventory.update(quantity: val)
        end
      end
    end
  end

  # updates actual time in labor-items/labor-details
  def update_labor_items_and_labor_details(labor_estimate_items)
    labor_estimate_items.each do |ei_params|
      estimate_item = estimate_items.find_by_id(ei_params['estimate_item_id'])
      estimate_item.labor_details.create(actual_labor_time: ei_params['actual_hours'], labor_cost: ei_params['labor_cost'],
        labor_item_id: estimate_item.labor_item_id, labor_time: ei_params['estimated_hours'], technician_id: ei_params['technician_id'])
      estimate_item.update(cost: estimate_item.labor_details.sum(:labor_cost))
    end
  end

  def check_inventory_available_quantity
    out_of_stock_op = []
    job_items.each do |item|
     inventory_items = []
     eis = item.estimate_items.where(saved_through: "Inventory")
     grouped_items = eis.group_by { |d| d[:part_num] }
     grouped_items.each do |k,v|
       quantity = 0
       v.each do |i|
         quantity += i.quantity
       end
       inventory = repair_shop.inventories.where(part_number: k).first
       if inventory.blank? || inventory.available_quantity + quantity  < quantity
        out_of_stock_op << item.id
       end
     end
    end
    out_of_stock_op
  end

  def self.index_ros(list, current_user, job_status='')
    list_ros = []
    if job_status.to_s.length.positive?
      list_ros = list == 'is_estimate_ros' ? get_estimate_ros_by_status(job_status) : get_ros_by_status(job_status)
    elsif list == 'my_ros'
      user_technician = current_user.technician
      list_ros = user_technician ? by_tech_id(user_technician.id) :
                                               state_open_ros.by_service_advisor_id(current_user.service_advisor&.id)
    elsif list == 'all_ros'
      list_ros = state_open_ros
    elsif list == 'is_estimate_ros'
      list_ros = is_estimate_ros
    elsif list == 'ros_history'
      all_jobs = current_user.chain.present? ?
                    Job.joins(:repair_shop).where('repair_shops.id IN (?)', current_user.chain.repair_shops.map(&:id))
                    : Job.joins(:repair_shop).where('repair_shops.id IN (?)', current_user.repair_shop_ids)
      list_ros = all_jobs.state_closed_ros
    elsif list == 'archived_ros'
      list_ros = is_archived_ros
    end
    list_ros
  end

  def self.include_vehicle
    includes(:vehicle, :vehicle_sub_model)
  end

  def self.include_show
    includes(:estimate, coupons_jobs: [coupon: [:repair_shop]], job_items: [:estimate_items, :customer_concern, :technician_diagnostic])
  end

  # searching all open ROs for technician or ROs operation/job_items belongs to technician.
  def self.by_tech_id(tech_id)
    tech_inspection_ids = []
    tech_job_ids = JobItem.where(job: state_open_ros.select('id')).where("'?' = ANY(technicians)", tech_id).pluck(:job_id)
    state_open_ros.includes(:inspections).each do |sor|
      sor.inspections.each do |insp|
        tech_inspection_ids << sor.id if insp.technician_available?(tech_id)
      end
    end
    state_open_ros.where(id: tech_job_ids).or(where(technician_id: tech_id)).or(where(id: tech_inspection_ids))
  end

  def self.by_service_advisor_id(id)
    where(service_advisor_id: id)
  end

  def self.load_dependencies
    includes(:vehicle, :customer, :technician, :inspections,
             :service_advisor, :notes, :lyfts_ordered_by_created,
             :messages_ordered_by_created, :job_items, estimate: :estimate_items)
  end

  def self.in_queue
    where(state: ['awaiting_diagnostic'])
  end

  def self.diagnostic_in_progress
    where(state: ['technician_performing_diagnostic'])
  end

  def self.diagnostic_complete
    where(state: ['diagnostic_complete']) && !try(:estimate)
  end

  def self.waiting_for_approval
    where(state: ['diagnostic_complete']) && try(:estimate) && !try(:estimate).approval_time.exists?
  end

  def self.approved
    where(state: ['diagnostic_complete']) && try(:estimate).approval_time.exists?
  end

  def self.repair_in_progress
    where(state: %w[diagnostic_complete parts_ordered parts_delayed parts_delivered repair_in_progress])
  end

  def self.complete
    where(state: 'finalized')
  end

  def self.green
    where(state_changed_at: (Time.now - GREEN_TIME_LIMIT)..Time.now)
  end

  def self.yellow
    where(state_changed_at: (Time.now - YELLOW_TIME_LIMIT)..(Time.now - GREEN_TIME_LIMIT))
  end

  def self.red
    where('state_changed_at < ?', Time.now - YELLOW_TIME_LIMIT)
  end

  def self.jobs_categorizing(jobs)
    occurrence = Job.find_occurrence(jobs)
    categories = occurrence.sort_by { |_key, value| value } if occurrence.present?
    Job.find_categories(categories)
  end

  def self.find_occurrence(jobs)
    counts = Hash.new 0
    jobs.map(&:current_categorizing).try(:each) do |item|
      counts[item] += 1
    end
    counts
  end

  def self.find_categories(categories)
    categorizing = []
    categories.try(:each) do |category|
      categorizing.push([category[0],category[1]])
    end
  end



  def new_checklist
    Checklist.new
  end

  def can_text
    !dont_text && customer.subscribed
  end

  def current_transition
    if state == 'technician_performing_diagnostic'
      'start_diagnostic'
    elsif state == 'diagnostic_complete'
      'end_diagnostic'
    elsif state == 'parts_ordered'
      'order_parts'
    elsif state == 'parts_delayed'
      'delay_parts'
    elsif state == 'parts_delivered'
      'receive_parts'
    elsif state == 'repair_in_progress'
      'start_repair'
    elsif state == 'repair_completed'
      'complete_repair'
    elsif state == 'finalized'
      'finalized'
    elsif state == 'repair_denied'
      'deny_repair'
    else
      'awaiting_diagnostic'
    end
  end

  def current_categorizing
    if (!on_site || estimate.nil?) && missing_info.empty?
      'new'
    elsif check_job_closed
      'job_closed'
    elsif parts_delayed? || (estimate&.approval_time && estimate&.unordered_parts) || (estimate && estimate
      .saved_time
      .present? && !estimate.approval_time) || !missing_info.empty? || (!check_job_closed && expected_by.past?)
      'need_attention'
    elsif expected_by.strftime('%Y-%m-%d %H:%M').between?(Time.now.strftime('%Y-%m-%d %H:%M'), (Time.now + 7_200_000).strftime('%Y-%m-%d %H:%M'))
      'expected_soon'
    else
      'in_progress'
    end
  end

  def job_type
    customer.jobs.where(repair_shop_id: repair_shop.id, state_closed: true).count > 1 ? 'repeat' : 'new'
  end

  def all_notes
    all = notes + vehicle.notes + customer.notes
    all.sort_by { |note| -note.created_at.to_i }
  end

  def time_ago
    "#{time_ago_in_words(updated_at)} ago"
  end

  def approved_job_items
    job_items.where.not(approval_type: nil)
  end

  def booked_estimate_amount
    grand_total('complete_total').to_f
  end

  def total_labor_time
    # labor_items.collect(&:labor_time_average).sum
    total = 0
    items = estimate_items.where.not(job_items: {state: 'declined'}).where(item_type: 'labor')
    items.each do |item|
      n = item.labor_details.sum(:actual_labor_time)
      total += n if n.present?
    end
    total
  end

  def core_parts
    job_items.map(&:core_parts).flatten
  end

  def set_work_timestamps
    if work_started_at.nil?
      if (state == 'repair_in_progress') || (state == 'repair_completed') || (state == 'finalized')
        update_attribute(:work_started_at, updated_at)
      end
    end
    if work_completed_at.nil?
      if state == 'repair_completed' || (state == 'finalized')
        update_attribute(:work_completed_at, updated_at)
      end
    end
  end

  # returns "See RO" if there are operations with different states
  def ro_state
    uniq_states = job_items.pluck(:state).uniq
    if uniq_states.compact == []
      if job_items.pluck(:approval_time).uniq.compact == []
        state
      elsif job_items.pluck(:approval_time).compact.count == job_items.pluck(:approval_time).count
        state
      else
        "See RO"
      end
    elsif uniq_states.compact != []
      if uniq_states.count == 1
        state
      else
        "See RO"
      end
    end
  end

  def unordered_parts
    estimate&.unordered_parts
  end

  def approved_parts
    approved = []
    job_items.where.not(approval_type: '').each do |j|
      details = j.part_details.where(part_cart_id: nil).includes(:estimate_item)
      approved.push(*details) if details.present?
    end
    approved
  end

  def check_parts_received
    if job_items.where(parts_received: nil).count.zero?
      update(parts_received: Time.now)
      # notify users & customer about parts received
      send_parts_delivered_text
    end
  end

  def total_remaining
    payment_total = payments.sum(:payment_amount)
    tr = grand_total.to_f - payment_total.to_f
    round_to_cents(tr)
  end

  # fetch maintenance-items for the vehicle
  def maintenance_intervals
    @result = car_service.maintenance(vehicle.vin, vehicle.mileage || mileage_in)
    MaintenanceItem.save_maintenance_items(@result)
  end

  def tsbs
    car_service.tsb(vehicle.vin).try(:[], 'data')
  end

  def recalls
    car_service.recalls(vehicle.vin).try(:[], 'data')
  end

  def tsbs_and_recalls
    f_recalls = recalls
    f_tsbs = tsbs
    if f_recalls && f_tsbs
      # f_recalls + f_tsbs
      { recalls: f_recalls, tsbs: f_tsbs }
    elsif f_recalls
      # f_recalls
      { recalls: f_recalls }
    elsif f_tsbs
      # f_tsbs
      { tsbs: f_tsbs }
    end
  end

  def build_estimate(job_items = nil)
    create_estimate if estimate.blank?
    create_job_item_estimate_items job_items if job_items&.any?
    create_estimate_keen_data
  end

  def create_estimate_keen_data
    ensure_em
    # # Keen.publish_async(:estimate_created,
    #                    shop_id: repair_shop_id.to_s,
    #                    chain_id: repair_shop.chain_id.to_s,
    #                    job_id: id,
    #                    customer_id: customer.id,
    #                    line_items: estimate.estimate_items.count,
    #                    total_amount: grand_total.to_f,
    #                    estimate: estimate)
  end

  # closes the job and declines all operations if none are approved.
  def close_job
    previous_job = customer.jobs.where(repair_shop: repair_shop, state_closed: false).state_open.last
    update(state_closed: true, closed_at: Time.zone.now)
    set_status(true)
    finalize unless state == 'finalized'
    update_for_vehicle_estimates
    payments.ar.each { |p| Payment.account_bal_update(p) }
    CreateReportJob.perform_later([self])

    if previous_job.present?
      previous_job.set_active_job_to_customer
    else
      send_survey_text SurveyQuestion.first
    end

    # CreateKeenForCloseJob.perform_later([self])
    Integrations::QuickbooksOnline::SendJobWorker.perform_async(repair_shop.id, self.id)
  end

  def set_finalized_at
    update(finalized_at: Time.zone.now)
  end

  def update_flag
    ji = job_items.where.not(state: "declined")
    if approval_status
      ji = ji.where.not(approval_time: nil)
    end
    update(flag_hours: ji.to_a.sum(&:flag_hours))
  end

  def mileage
    mileage_out || mileage_in
  end

  def update_customer_static
    if customer.present?
      self.customer_name = customer.business_name
    end
  end

  def self.jobs_total_sale_tax(jobs_data)
    tax = 0
    pretax_sale = 0
    if jobs_data.present?
      jobs_data.each do |job|
        tax += job.get_total_tax
        pretax_sale += job.get_sub_total
      end
    end
    {tax: tax, pretax_sale: pretax_sale}
  end

  def update_technician_oversight(technician_oversight_details)
    update(upper_technician_id: technician_oversight_details[:upper_technician_id], lower_technician_id: technician_oversight_details[:lower_technician_id], courtesy_technician_id: technician_oversight_details[:courtesy_technician_id], service_advisor_id: technician_oversight_details[:service_advisor_id], safety_technician_id: technician_oversight_details[:safety_technician_id])
  end

  def update_cashier_and_advisor(cashier_id, advisor_id)
    update(cashier_id: cashier_id, service_advisor_id: advisor_id)
  end

  def self.include_cus_job
    includes(:repair_shop,:estimate, :customer, :job_items, :coupons_jobs, :coupons, service_advisor: [:user], technician: [:user], vehicle: [:vehicle_sub_model], estimate_items: [:part_detail])
  end

  def self.update_tax_exempt_status(status = false)
    update_all(tax_exempt: status)
  end

  def update_po
    po_data = self.purchase_orders
    if po_data.present?
      po_data.each do |po|
        po.posted_at = Date.today
        po.save
      end
    end
  end

  def operation_items
    job_items.where(is_diagnostic_step: false)
  end

  def trackable_inspections
    inspections.where(trackable: true)
  end

  #override destroy method to allow child models to check.
  def destroy
    self.destroying = true
    super
  end

  def existing_job
    params = {
      repair_shop_id: repair_shop_id,
      warranty_or_policy: warranty_or_policy
    }
    VehicleParams.new(params).existing_job_in_db?(vehicle_id)
  end

  def send_finalized_invoice
    if repair_shop.option_enabled? "customer_estimate_invoice"
      UpdateJobJob.perform_now(self, nil, true)
    end
  end

  def ar_account_name
    name = ''
    payments =  try(:payments)&.where&.not(account_id: nil)&.includes(account: [:customerable])
    payments&.each_with_index do |res, i|
      customerable_obj = res&.account&.customerable
      if res&.account&.customerable_type == 'Customer'
        name += customerable_obj.fleet ? customerable_obj.business_name : customerable_obj.name
      else
        name += customerable_obj.name
      end
      unless (payments.length - 1) == i
        name += ' and '
      end
    end
    name
  end

  def created_at_format_date
    if created_at.present?
      today = repair_shop.shop_time(Time.now)
      date = repair_shop.shop_time(created_at)
      if date.strftime("%F") == today.strftime("%F")
        date.strftime("%I:%M%p")
      else
        date.strftime("%m/%d")
      end
    end
  end

  def sf_flag_enabled
    repair_shop.option_enabled?('wip_sf_status')
  end

  private
  def pdf_send_data
    hash = {}
    customer_concerns = self.customer_concerns
    diagnostic_step_instances = self.diagnostic_step_instances.where(customer_concern_id: nil)
    job_items = self.job_items.where(customer_concern: nil, diagnostic_step_instance: nil)

    hash[:estimate_items] = %i[estimate labor_details labor_item part_detail]
    job_items = job_items.includes(hash).reorder(:position)

    f_items = customer_concerns + diagnostic_step_instances + job_items

    f_items.sort_by { |obj| obj.position || 0 } unless f_items.empty?
  end

  # create RO's inspections using RO's profit_center's templates
  def create_inspections
    Inspection.create_inspections_for_ro(id)
  end

  def job_item_params(job_item)
    job_item.permit(:customer_states, :operation_id, :customer_description, :partstech_id, :maintenance_item_id, :tag, :description,
                    :customer_concern_id, :technician_diagnostic_id, :diagnostic_step_instance_id, :disable_supplies,
                    :require_stock_parts, :package_price, :labor_price, :motor_name, :motor_group_id, :motor_category_id, :motor_subgroup_id)
    # @job_item = job_items.create(customer_states: job_item["customer_states"], operation_id: job_item["operation_id"], customer_description: job_item["customer_description"], partstech_id: job_item["partstech_id"])
  end

  def copy_items_from_previous_job
    CopyJobItem.recreate_declined_operations(self)
  end

  def phone_exists(attributes)
    valid = Phonelib.valid?(attributes['phone'])
    exists = Customer.find_by_phone(Phonelib.parse(attributes['phone']).e164)
    valid && exists
  end

  def update_static_fields
    self.profit_center_name = ProfitCenter.find(profit_center_id).name if profit_center_id_changed?
    self.service_advisor_name = ServiceAdvisor.find(service_advisor_id).name if service_advisor_id_changed? && service_advisor.present? && service_advisor_id.present?
    self.technician_name = Technician.find(technician_id).name if technician_id_changed? && technician_id.present?
    self.technician_name = nil if technician_id_changed? && technician_id.blank?
    update_vehicle_static

    unless vehicle_id_changed?
      self.new_vehicle = true
    end
  end

  def update_vehicle_static
    veh =   vehicle  || Vehicle.find(vehicle_id)
    self.vehicle_name = veh.vehicle_name
    if new_vehicle
      self.new_vehicle = false
    end
    update_customer_static
  end

  def update_appointment
    appointment.update(service_advisor_id: service_advisor_id, technician_id: technician_id)
  end

  def update_contact_preference
    update(contact_preference: customer&.contact_preference.present? ? customer&.contact_preference : 'Text')
  end

  def set_mileage_out
    update(mileage_out: mileage_in) if mileage_in.present?
  end

  def set_denied_status
    self.approval_status = 'deferred'
  end

  def ensure_em
    unless EventMachine.reactor_running? && EventMachine.reactor_thread.alive?
      Thread.new { EventMachine.run }
      sleep 1
    end
  end

  def set_vehicle_customer
    if vehicle.customer_id.blank?
      vehicle.customer = customer
      vehicle.save
    end
  end

  def update_for_vehicle_estimates
    chain_shop_ids = RepairShop.find(repair_shop_id).chain&.repair_shops&.pluck(:id)
    jobs = Job.where(vehicle_id: vehicle_id,
      is_estimate: true,
      warranty_or_policy: warranty_or_policy,
      repair_shop_id: chain_shop_ids || repair_shop_id)
    jobs.each do |j|
      UpdateJobWorker.new.perform(j.id, 'existing_job')
    end
  end

  def sync_qbo_invoices
    Integrations::QuickbooksOnline::SyncQboInvoicesWorker.perform_async(repair_shop&.id, self.id)
  end
end
