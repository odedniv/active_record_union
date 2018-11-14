module ActiveRecord
  class Relation
    module Union

      SET_OPERATION_TO_AREL_CLASS = {
        union:     Arel::Nodes::Union,
        union_all: Arel::Nodes::UnionAll
      }

      def union(relation_or_where_arg, *args)
        set_operation(:union, relation_or_where_arg, *args)
      end

      def union_all(relation_or_where_arg, *args)
        set_operation(:union_all, relation_or_where_arg, *args)
      end

      private

      def set_operation(operation, relation_or_where_arg, *args)
        others = if relation_or_where_arg.is_a?(Relation)
                   [relation_or_where_arg, *args]
                 else
                   [@klass.where(relation_or_where_arg, *args)]
                 end

        verify_relations_for_set_operation!(operation, self, *others)

        asts = [self.arel.ast, *others.map { |o| o.arel.ast }]

        # Postgres allows ORDER BY in the UNION subqueries if each subquery is surrounded by parenthesis
        # but SQLite does not allow parens around the subqueries
        unless self.connection.visitor.is_a?(Arel::Visitors::SQLite)
          asts = asts.map { |ast| Arel::Nodes::Grouping.new(ast) }
        end

        arel_class = SET_OPERATION_TO_AREL_CLASS[operation]
        set = asts.reduce { |left, right| arel_class.new(left, right) }
        from = Arel::Nodes::TableAlias.new(set, @klass.arel_table.name)
        build_union_relation(from, others)
      end

      if ActiveRecord.gem_version >= Gem::Version.new('5.2.0.beta2')
        # Since Rails 5.2, binds are maintained only in the Arel AST.
        def build_union_relation(arel_table_alias, _others)
          @klass.unscoped.from(arel_table_alias)
        end
      elsif ActiveRecord::VERSION::MAJOR >= 5
        # In Rails >= 5.0, < 5.2, binds are maintained only in ActiveRecord
        # relations and clauses.
        def build_union_relation(arel_table_alias, others)
          relation = @klass.unscoped.spawn
          relation.from_clause =
            UnionFromClause.new(arel_table_alias, nil,
                                self.bound_attributes + others.flat_map(&:bound_attributes))
          relation
        end

        class UnionFromClause < ActiveRecord::Relation::FromClause
          def initialize(value, name, bound_attributes)
            super(value, name)
            @bound_attributes = bound_attributes
          end

          def binds
            @bound_attributes
          end
        end
      else
        # In Rails 4.x, binds are maintained in both ActiveRecord relations and
        # clauses and also in their Arel ASTs.
        def build_union_relation(arel_table_alias, others)
          relation = @klass.unscoped.from(arel_table_alias)
          relation.bind_values = self.arel.bind_values + self.bind_values +
                                 others.flat_map { |o| o.arel.bind_values } + others.flat_map { |o| o.bind_values }
          relation
        end
      end

      def verify_relations_for_set_operation!(operation, *relations)
        includes_relations = relations.select { |r| r.includes_values.any? }

        if includes_relations.any?
          raise ArgumentError.new("Cannot #{operation} relation with includes.")
        end

        preload_relations = relations.select { |r| r.preload_values.any? }
        if preload_relations.any?
          raise ArgumentError.new("Cannot #{operation} relation with preload.")
        end

        eager_load_relations = relations.select { |r| r.eager_load_values.any? }
        if eager_load_relations.any?
          raise ArgumentError.new("Cannot #{operation} relation with eager load.")
        end
      end
    end
  end
end
