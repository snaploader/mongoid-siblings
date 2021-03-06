module Mongoid

  # Adds methods to easily access your document's siblings.
  module Siblings
    extend ActiveSupport::Concern
    
    included do
      cattr_accessor :default_sibling_scope
    end

    # Returns this document's siblings.
    #
    # @example Retrieve document's siblings
    #   book.siblings
    #
    # @see #siblings_and_self
    def siblings(options = {})
      self.siblings_and_self(options).excludes(id: self.id)
    end
    
    # Returns this document's siblings and itself.
    #
    # @example Retrieve document's siblings and itself within a certain scope.
    #   book.siblings_and_self(scope: :author)
    #
    # @example Retrieve what would be document's siblings if it had another scope value.
    #   
    #   book.siblings_and_self(
    #     scope:        :author, 
    #     scope_values: { 
    #       author: other_author 
    #     }
    #   )
    #
    # @param [ Hash ] options The options.
    #
    # @option options [ Array<Symbol>, Symbol ] scope One or more relations or 
    #   attributes that siblings of this object need to have in common.
    # @option options [ Hash<Symbol, Object> ] scope_values Optional alternative
    #   values to use to determine siblingship.
    #
    # @return [ Mongoid::Criteria ] Criteria to retrieve the document's siblings.
    def siblings_and_self(options = {})
      scopes        = options[:scope]         || self.default_sibling_scope
      scope_values  = options[:scope_values]  || {}

      scopes = Array.wrap(scopes).compact

      
      criteria = base_document_class.all

      detail_scopes = []

      # Find out what scope determines the root criteria. This can be 
      # [klass].all or self.[relation].
      # It is assumed that for `scopes: [:rel1, :rel2]`, sibling objects always
      # have the same `rel1` *and* `rel2`, and that two objects with the same
      # `rel1` will always have the same `rel2`.
      scopes.reverse_each do |scope|
        scope_value = scope_values.fetch(scope) { self.send(scope) }
        
        relation_metadata = self.reflect_on_association(scope)
        if relation_metadata && scope_value
          proxy = self.siblings_through_relation(scope, scope_value)
          if proxy
            criteria = proxy.criteria
            next
          end  
        end

        detail_scopes << scope
      end

      # Apply detail criteria, to make sure siblings share every simple 
      # attribute or nil-relation. 
      detail_scopes.each do |scope|
        scope_value = scope_values.fetch(scope) { self.send(scope) }

        relation_metadata = self.reflect_on_association(scope)
        if relation_metadata
          criteria = criteria.where(relation_metadata.key => scope_value)

          if scope_value && relation_metadata.polymorphic?
            type        = scope_value.class.name
            inverse_of  = send(relation_metadata.inverse_of_field) 
            
            criteria = criteria.where(relation_metadata.inverse_type      => type)
            criteria = criteria.any_in(relation_metadata.inverse_of_field => [inverse_of, nil])
          end
        else
          criteria = criteria.where(scope => scope_value)
        end
      end

      criteria
    end
    
    # Is this document a sibling of the other document?
    #
    # @example Is this document a sibling of the other document?
    #   book.sibling_of?(other_book, scope: :author)
    #
    # @param [ Document ] other The document to check against.
    # @param [ Hash ] options The options.
    #
    # @option options [ Array<Symbol>, Symbol ] scope One or more relations and 
    #   attributes that siblings of this object need to have in common.
    # @option options [ Hash<Symbol, Object> ] scope_values Optional alternative
    #   values for this document to use to determine siblings.
    # @option options [ Hash<Symbol, Object> ] other_scope_values Optional 
    #   alternative values for the other document to use to determine 
    #   siblingship.
    #
    # @return [ Boolean ] True if the document is a sibling of the other 
    #   document.
    def sibling_of?(other, options = {})
      scopes              = options[:scope]               || self.default_sibling_scope
      scope_values        = options[:scope_values]        || {}
      other_scope_values  = options[:other_scope_values]  || {}

      scopes = Array.wrap(scopes).compact


      return false if base_document_class != base_document_class(other)

      scopes.each do |scope|
        scope_value       = scope_values.fetch(scope)       { self.send(scope) }
        other_scope_value = other_scope_values.fetch(scope) { other.send(scope) }

        return false if scope_value != other_scope_value
      end
      
      true
    end
    
    # Makes this document a sibling of the other document.
    #
    # This is done by copying over the values used to determine siblingship 
    # from the other document.
    #
    # @example Make document a sibling of the other document.
    #   book.become_sibling_of(book_of_other_author, scope: :author)
    #
    # @param [ Document ] other The document to become a sibling of.
    # @param [ Hash ] options The options.
    #
    # @option options [ Array<Symbol>, Symbol ] scope One or more relations and 
    #   attributes that siblings of this object need to have in common.
    # @option options [ Hash<Symbol, Object> ] other_scope_values Optional 
    #   alternative values to use to determine siblingship.
    #
    # @return [ Boolean ] True if the document was made a sibling of the other 
    #   document.
    def become_sibling_of(other, options = {})
      return true if self.sibling_of?(other, options)

      scopes              = options[:scope]               || self.default_sibling_scope
      other_scope_values  = options[:other_scope_values]  || {}

      scopes = Array.wrap(scopes).compact


      return false if base_document_class != base_document_class(other)

      scopes.each do |scope|
        other_scope_value = other_scope_values.fetch(scope) { other.send(scope) }

        relation_metadata = self.reflect_on_association(scope)
        if relation_metadata && other_scope_value
          inverse_metadata = other.intelligent_inverse_metadata(scope, other_scope_value)
          if inverse_metadata
            inverse = inverse_metadata.name
            if inverse_metadata.many?
              other_scope_value.send(inverse) << self
            else
              other_scope_value.send("#{inverse}=", self)
            end

            next
          end
        end
        self.send("#{scope}=", other_scope_value)
      end
    end

    def become_sibling_of!(*args)
      become_sibling_of(*args) && save!
    end

    alias_method :sibling_of!, :become_sibling_of!

    def intelligent_inverse(name, other = nil)
      other ||= self.send(name)

      relation_metadata = self.reflect_on_association(name)
      return nil if relation_metadata.nil?
      inverses = relation_metadata.inverses(other)
      
      return nil if inverses.nil? || inverses.empty?
      
      if inverses.length == 1
        inverses.first
      elsif relation_metadata.polymorphic?
        inverse_of = send(relation_metadata.inverse_of_field) 
        inverses.find { |inverse| inverse == inverse_of }
      else
        inverses.find do |inverse| 
          inverse_metadata = other.reflect_on_association(inverse)
          children = \
            if inverse_metadata.embedded?
              other.send(inverse_metadata.name)
            else
              inverse_metadata.criteria(other, other.class)
            end
          children.include?(self)
        end
      end
    end

    def intelligent_inverse_metadata(name, other = nil)
      other ||= self.send(name)
      inverse = self.intelligent_inverse(name, other)
      return nil if inverse.nil?

      other.reflect_on_association(inverse)
    end

    def siblings_through_relation(name, other)
      inverse_metadata = self.intelligent_inverse_metadata(name, other)
      return nil if inverse_metadata.nil?
      
      if inverse_metadata.embedded?
        other.send(inverse_metadata.name)
      else
        inverse_metadata.criteria(other, other.class)
      end
    end

    def base_document_class(doc = self)
      base_document_klass = doc.class
      while base_document_klass.superclass.include?(Mongoid::Document)
        base_document_klass = base_document_klass.superclass
      end
      base_document_klass
    end
  end
end