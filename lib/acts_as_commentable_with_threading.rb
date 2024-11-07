# frozen_string_literal: true

require 'active_record'
require 'awesome_nested_set'
require 'pagy'

module Acts
  module CommentableWithThreading
    extend ActiveSupport::Concern

    included do
      include CollectiveIdea::Acts::NestedSet unless respond_to?(:acts_as_nested_set)
      include Pagy::Backend
    end

    module ClassMethods
      def acts_as_commentable
        has_many :comment_threads, 
                 class_name: 'Comment', 
                 as: :commentable,
                 dependent: :destroy

        include LocalInstanceMethods
        extend SingletonMethods
      end
    end

    module SingletonMethods
      # Fetch paginated comments with Pagy
      def find_comments_for(obj, page: 1, items: 20)
        collection = Comment.includes(:user)
                          .where(commentable_id: obj.id,
                                commentable_type: obj.class.base_class.name)
                          .order('created_at DESC')
        
        pagy, comments = pagy(collection, page: page, items: items)
        [pagy, comments]
      end

      # Fetch user's comments with Pagy
      def find_comments_by_user(user, page: 1, items: 20)
        collection = Comment.includes(:commentable)
                          .where(user_id: user.id, 
                                commentable_type: base_class.name)
                          .order('created_at DESC')
        
        pagy, comments = pagy(collection, page: page, items: items)
        [pagy, comments]
      end
    end

    module LocalInstanceMethods
      # Fetch root comments with Pagy pagination and caching
      def root_comments(page: 1, items: 20)
        collection = comment_threads
                      .includes(:user)
                      .where(parent_id: nil)
                      .order('created_at DESC')

        Rails.cache.fetch([self, 'root_comments', page, items], expires_in: 1.hour) do
          pagy, comments = pagy(collection, page: page, items: items)
          [pagy, comments]
        end
      end

      # Fetch nested comments with configurable depth
      def nested_comments(depth: nil, page: 1, items: 20)
        collection = root_comments(page: page, items: items).last

        Rails.cache.fetch([self, 'nested_comments', depth, page, items], expires_in: 1.hour) do
          includes_clause = depth.nil? ? recursive_includes : includes_to_depth(depth)
          pagy, comments = pagy(
            collection.includes(includes_clause),
            page: page,
            items: items
          )
          [pagy, comments]
        end
      end

      # Helper method to build recursive includes for infinite depth
      private def recursive_includes
        { children: { children: { children: :children } } }
      end

      # Helper method to build includes clause to specific depth
      private def includes_to_depth(depth)
        return {} if depth <= 0
        { children: includes_to_depth(depth - 1) }
      end

      # Fetch comments ordered by submission with Pagy
      def comments_ordered_by_submitted(page: 1, items: 20)
        collection = Comment.includes(:user)
                          .where(commentable_id: id, 
                                commentable_type: self.class.name)
                          .order('created_at DESC')
        
        pagy, comments = pagy(collection, page: page, items: items)
        [pagy, comments]
      end

      # Add a comment with proper nested set positioning
      def add_comment(comment)
        transaction do
          comment.commentable = self
          if comment.parent_id.present?
            parent_comment = comment_threads.find(comment.parent_id)
            comment.move_to_child_of(parent_comment)
          end
          comment.save
          Rails.cache.delete_matched("#{cache_key}/*")
        end
      end

      def comments?
        Rails.cache.fetch([self, 'has_comments'], expires_in: 1.hour) do
          Comment.where(commentable_id: id, 
                       commentable_type: self.class.name)
                .exists?
        end
      end
    end
  end
end

# Comment model extensions
module CommentExtensions
  extend ActiveSupport::Concern

  included do
    belongs_to :commentable, polymorphic: true, touch: true
    belongs_to :user
    
    validates :body, presence: true
    validates :user, presence: true
    
    scope :recent, -> { order('created_at DESC') }
    scope :oldest, -> { order('created_at ASC') }
    scope :by_user, ->(user) { where(user_id: user.id) }
    
    acts_as_nested_set scope: [:commentable_id, :commentable_type]

    after_commit :clear_cache

    private

    def clear_cache
      return unless commentable
      Rails.cache.delete_matched("#{commentable.cache_key}/*")
    end
  end

  def cache_key
    super + '/comments'
  end

  # Calculate the depth of nesting for this comment
  def depth
    ancestors.count
  end

  # Get all descendants to any depth
  def all_replies
    descendants.includes(:user).order('created_at ASC')
  end

  # Get replies paginated
  def paginated_replies(page: 1, items: 20)
    collection = descendants.includes(:user).order('created_at ASC')
    pagy, replies = pagy(collection, page: page, items: items)
    [pagy, replies]
  end
end

ActiveRecord::Base.include Acts::CommentableWithThreading

# Example Comment model implementation
class Comment < ActiveRecord::Base
  include CommentExtensions
end
