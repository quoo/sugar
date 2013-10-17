# encoding: utf-8

class Discussion < Exchange
  include SearchableExchange
  include Viewable

  has_many   :discussion_relationships, dependent: :destroy
  belongs_to :category, counter_cache: true

  validates_presence_of :category_id

  # Flag for trusted status, which will update after save if it has been changed.
  attr_accessor :update_trusted

  scope :with_category, -> { includes(:poster, :last_poster, :category) }
  scope :for_view,      -> { sorted.with_posters.with_category }

  validate   :inherit_trusted_from_category
  after_save :update_trusted_status

  class << self
    def popular_in_the_last(days=7.days)
      select('exchanges.*, COUNT(posts.id) AS recent_posts_count')
        .joins(:posts)
        .where('posts.created_at > ?', days.ago)
        .group('exchanges.id')
        .order('recent_posts_count DESC')
    end
  end

  def participants
    User.find_by_sql(
      "SELECT u.*, MAX(p.created_at) AS last_post_at " +
      "FROM users u, posts p " +
      "WHERE p.exchange_id = #{self.id} AND p.user_id = u.id " +
      "GROUP BY u.id "
    )
  end

  def editable_by?(user)
    (user && (user.moderator? || user == self.poster)) ? true : false
  end

  def postable_by?(user)
    (user && (user.moderator? || !self.closed?)) ? true : false
  end

  private

  def inherit_trusted_from_category
    self.trusted = self.category.trusted if self.category
    true
  end

  def update_trusted_status
    if self.trusted_changed?
      self.posts.update_all(trusted: self.trusted?)
      self.discussion_relationships.update_all(trusted: self.trusted?)
      self.participants.each do |user|
        user.update_column(:public_posts_count, user.discussion_posts.where(trusted: false).count)
      end
    end
  end

end
