require 'active_record/connection_adapters/postgresql_adapter'

ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.class_eval do
  unless instance_methods.include?(:to_sql_without_pgcrypto) || instance_methods.include?('to_sql_without_pgcrypto')
    alias :to_sql_without_pgcrypto :to_sql
  end

  def to_sql(arel, *args)
    arel = Marshal.load(Marshal.dump(arel)) rescue arel = arel.dup # TODO: Need a better way to avoid mutation
    case arel
    when Arel::InsertManager
      pgcrypto_tweak_insert(arel)
    when Arel::SelectManager
      pgcrypto_tweak_select(arel)
    when Arel::UpdateManager
      pgcrypto_tweak_update(arel)
    end
    to_sql_without_pgcrypto(arel, *args)
  end

  private
  def pgcrypto_tweak_insert(arel)
    if arel.ast.relation.name.to_s == PGCrypto::Column.table_name.to_s
      return unless key = PGCrypto.keys[:public]
      arel.ast.columns.each_with_index do |column, i|
        if column.name == 'value'
          value = arel.ast.values.expressions[i]
          quoted_value = quote_string(value)
          encryption_instruction = %[pgp_pub_encrypt(#{quoted_value}, #{key.dearmored})]
          arel.ast.values.expressions[i] = Arel::Nodes::SqlLiteral.new(encryption_instruction)
        end
      end
    end
  end

  def pgcrypto_tweak_select(arel)
    return unless key = PGCrypto.keys[:private]
    # We start by looping through each "core," which is just
    # a SelectStatement and correcting plain-text queries
    # against an encrypted column...
    table_name = nil
    joins = {}
    arel.ast.cores.each do |core|
      # Yeah, I'm lazy. Whatevs.
      next unless core.is_a?(Arel::Nodes::SelectCore)

      encrypted_columns = PGCrypto[table_name = core.source.left.name]
      next if encrypted_columns.empty?

      # We loop through each WHERE specification to determine whether or not the
      # PGCrypto column should be JOIN'd upon; in which case, we, like, do it.
      core.wheres.each do |where|
        pgcrypto_modify_where(table_name, key, joins, where)
      end
    end
    if joins.any?
      arel.join(Arel::Nodes::SqlLiteral.new("CROSS JOIN (SELECT #{key.dearmored} AS #{key.name}) AS pgcrypto_keys"))
      joins.each do |table, columns|
        columns.each do |column|
          column = quote_string(column)
          as_table = "#{PGCrypto::Column.table_name}_#{column}"
          arel.join(Arel::Nodes::SqlLiteral.new(%[
            JOIN "#{PGCrypto::Column.table_name}" AS "#{as_table}" ON "#{as_table}"."owner_id" = "#{table}"."id" AND "#{as_table}"."owner_table" = '#{quote_string(table)}' AND "#{as_table}"."name" = '#{column}'
          ]))
        end
      end
    end
  end

  def pgcrypto_modify_where(table_name, key, joins, children)
    children.each do |child|
      if child.respond_to?(:children)
        pgcrypto_modify_where(table_name, key, joins, child.children)
      elsif child.respond_to?(:expr)
        pgcrypto_modify_where(table_name, key, joins, [child.expr])
      else
        next unless child.respond_to?(:left) and child.left.respond_to?(:name)
        child_table_name = table_name
        if child.left.respond_to?(:relation) && !child.left.relation.is_a?(Arel::Nodes::TableAlias)
          child_table_name = child.left.relation.name.classify.constantize.table_name
        end
        if PGCrypto[child_table_name]
          column_options = PGCrypto[child_table_name][child.left.name.to_s]
        else
          column_options = PGCrypto[table_name][child.left.name.to_s]
        end
        next unless column_options
        joins[child_table_name] ||= []
        joins[child_table_name].push(child.left.name.to_s) unless joins[child_table_name].include?(child.left.name.to_s)
        pgcrypto_table = PGCrypto::Column.arel_table.alias("#{PGCrypto::Column.table_name}_#{child.left.name}")
        keys_table = Arel::Table.new('pgcrypto_keys')
        decrypt_node_arguments = [pgcrypto_table[:value], keys_table[key.name]]
        decrypt_node_arguments << key.password if key.password
        decrypt_node = Arel::Nodes::NamedFunction.new('pgp_pub_decrypt', decrypt_node_arguments)
        if column_options[:column_type]
          column_type_node = Arel::Nodes::SqlLiteral.new(column_options[:column_type].to_s)
          decrypt_node = Arel::Nodes::InfixOperation.new('::', decrypt_node, column_type_node)
        end
        child.left = decrypt_node
      end
    end
  end

  def pgcrypto_tweak_update(arel)
    if arel.ast.relation.name.to_s == PGCrypto::Column.table_name.to_s
      # Loop through the assignments and make sure we take care of that whole
      # NULL value thing!
      value = arel.ast.values.select{|value| value.respond_to?(:left) && value.left.name == 'value' }.first
      if value.right.nil?
        value.right = Arel::Nodes::SqlLiteral.new('NULL')
      elsif key = PGCrypto.keys[:public]
        quoted_right = quote_string(value.right)
        encryption_instruction = %[pgp_pub_encrypt('#{quoted_right}', #{key.dearmored})]
        value.right = Arel::Nodes::SqlLiteral.new(encryption_instruction)
      end
    end
  end
end
