# frozen_string_literal: true
# encoding: utf-8

# Copyright (C) 2014-2020 MongoDB Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'mongo/bulk_write/result'
require 'mongo/bulk_write/transformable'
require 'mongo/bulk_write/validatable'
require 'mongo/bulk_write/combineable'
require 'mongo/bulk_write/ordered_combiner'
require 'mongo/bulk_write/unordered_combiner'
require 'mongo/bulk_write/result_combiner'

module Mongo
  class BulkWrite
    extend Forwardable
    include Operation::ResponseHandling

    # @return [ Mongo::Collection ] collection The collection.
    attr_reader :collection

    # @return [ Array<Hash, BSON::Document> ] requests The requests.
    attr_reader :requests

    # @return [ Hash, BSON::Document ] options The options.
    attr_reader :options

    # Delegate various methods to the collection.
    def_delegators :@collection,
                   :database,
                   :cluster,
                   :write_with_retry,
                   :nro_write_with_retry,
                   :next_primary

    def_delegators :database, :client

    # Execute the bulk write operation.
    #
    # @example Execute the bulk write.
    #   bulk_write.execute
    #
    # @return [ Mongo::BulkWrite::Result ] The result.
    #
    # @since 2.1.0
    def execute
      operation_id = Monitoring.next_operation_id
      result_combiner = ResultCombiner.new
      operations = op_combiner.combine

      client.send(:with_session, @options) do |session|
        context = Operation::Context.new(client: client, session: session)
        operations.each do |operation|
          if single_statement?(operation)
            write_concern = write_concern(session)
            write_with_retry(session, write_concern) do |server, txn_num|
              server.with_connection(service_id: context.service_id) do |connection|
                execute_operation(
                  operation.keys.first,
                  operation.values.flatten,
                  connection,
                  context,
                  operation_id,
                  result_combiner,
                  session,
                  txn_num)
              end
            end
          else
            nro_write_with_retry(session, write_concern) do |server|
              server.with_connection(service_id: context.service_id) do |connection|
                execute_operation(
                  operation.keys.first,
                  operation.values.flatten,
                  connection,
                  context,
                  operation_id,
                  result_combiner,
                  session)
              end
            end
          end
        end
      end
      result_combiner.result
    end

    # Create the new bulk write operation.
    #
    # @api private
    #
    # @example Create an ordered bulk write.
    #   Mongo::BulkWrite.new(collection, [{ insert_one: { _id: 1 }}])
    #
    # @example Create an unordered bulk write.
    #   Mongo::BulkWrite.new(collection, [{ insert_one: { _id: 1 }}], ordered: false)
    #
    # @example Create an ordered mixed bulk write.
    #   Mongo::BulkWrite.new(
    #     collection,
    #     [
    #       { insert_one: { _id: 1 }},
    #       { update_one: { filter: { _id: 0 }, update: { '$set' => { name: 'test' }}}},
    #       { delete_one: { filter: { _id: 2 }}}
    #     ]
    #   )
    #
    # @param [ Mongo::Collection ] collection The collection.
    # @param [ Array<Hash, BSON::Document> ] requests The requests.
    # @param [ Hash, BSON::Document ] options The options.
    #
    # @since 2.1.0
    def initialize(collection, requests, options = {})
      @collection = collection
      @requests = requests
      @options = options || {}
    end

    # Is the bulk write ordered?
    #
    # @api private
    #
    # @example Is the bulk write ordered?
    #   bulk_write.ordered?
    #
    # @return [ true, false ] If the bulk write is ordered.
    #
    # @since 2.1.0
    def ordered?
      @ordered ||= options.fetch(:ordered, true)
    end

    # Get the write concern for the bulk write.
    #
    # @api private
    #
    # @example Get the write concern.
    #   bulk_write.write_concern
    #
    # @return [ WriteConcern ] The write concern.
    #
    # @since 2.1.0
    def write_concern(session = nil)
      @write_concern ||= options[:write_concern] ?
        WriteConcern.get(options[:write_concern]) :
        collection.write_concern_with_session(session)
    end

    private

    SINGLE_STATEMENT_OPS = [ :delete_one,
                             :update_one,
                             :insert_one ].freeze

    def single_statement?(operation)
      SINGLE_STATEMENT_OPS.include?(operation.keys.first)
    end

    def base_spec(operation_id, session)
      {
        :db_name => database.name,
        :coll_name => collection.name,
        :write_concern => write_concern(session),
        :ordered => ordered?,
        :operation_id => operation_id,
        :bypass_document_validation => !!options[:bypass_document_validation],
        :max_time_ms => options[:max_time_ms],
        :options => options,
        :id_generator => client.options[:id_generator],
        :session => session,
        :comment => options[:comment]
      }
    end

    def execute_operation(name, values, connection, context, operation_id, result_combiner, session, txn_num = nil)
      validate_collation!(connection)
      validate_array_filters!(connection)
      validate_hint!(connection)

      unpin_maybe(session) do
        if values.size > connection.description.max_write_batch_size
          split_execute(name, values, connection, context, operation_id, result_combiner, session, txn_num)
        else
          result = send(name, values, connection, context, operation_id, session, txn_num)

          add_server_diagnostics(connection) do
            add_error_labels(connection, context) do
              result_combiner.combine!(result, values.size)
            end
          end
        end
      end
    # With OP_MSG (3.6+ servers), the size of each section in the message
    # is independently capped at 16m and each bulk operation becomes
    # its own section. The size of the entire bulk write is limited to 48m.
    # With OP_QUERY (pre-3.6 servers), the entire bulk write is sent as a
    # single document and is thus subject to the 16m document size limit.
    # This means the splits differ between pre-3.6 and 3.6+ servers, with
    # 3.6+ servers being able to split less.
    rescue Error::MaxBSONSize, Error::MaxMessageSize => e
      raise e if values.size <= 1
      unpin_maybe(session) do
        split_execute(name, values, connection, context, operation_id, result_combiner, session, txn_num)
      end
    end

    def op_combiner
      @op_combiner ||= ordered? ? OrderedCombiner.new(requests) : UnorderedCombiner.new(requests)
    end

    def split_execute(name, values, connection, context, operation_id, result_combiner, session, txn_num)
      execute_operation(name, values.shift(values.size / 2), connection, context, operation_id, result_combiner, session, txn_num)

      txn_num = session.next_txn_num if txn_num
      execute_operation(name, values, connection, context, operation_id, result_combiner, session, txn_num)
    end

    def delete_one(documents, connection, context, operation_id, session, txn_num)
      QueryCache.clear_namespace(collection.namespace)

      spec = base_spec(operation_id, session).merge(:deletes => documents, :txn_num => txn_num)
      Operation::Delete.new(spec).bulk_execute(connection, context: context)
    end

    def delete_many(documents, connection, context, operation_id, session, txn_num)
      QueryCache.clear_namespace(collection.namespace)

      spec = base_spec(operation_id, session).merge(:deletes => documents)
      Operation::Delete.new(spec).bulk_execute(connection, context: context)
    end

    def insert_one(documents, connection, context, operation_id, session, txn_num)
      QueryCache.clear_namespace(collection.namespace)

      spec = base_spec(operation_id, session).merge(:documents => documents, :txn_num => txn_num)
      Operation::Insert.new(spec).bulk_execute(connection, context: context)
    end

    def update_one(documents, connection, context, operation_id, session, txn_num)
      QueryCache.clear_namespace(collection.namespace)

      spec = base_spec(operation_id, session).merge(:updates => documents, :txn_num => txn_num)
      Operation::Update.new(spec).bulk_execute(connection, context: context)
    end
    alias :replace_one :update_one

    def update_many(documents, connection, context, operation_id, session, txn_num)
      QueryCache.clear_namespace(collection.namespace)

      spec = base_spec(operation_id, session).merge(:updates => documents)
      Operation::Update.new(spec).bulk_execute(connection, context: context)
    end

    private

    def validate_collation!(connection)
      if op_combiner.has_collation? && !connection.features.collation_enabled?
        raise Error::UnsupportedCollation.new
      end
    end

    def validate_array_filters!(connection)
      if op_combiner.has_array_filters? && !connection.features.array_filters_enabled?
        raise Error::UnsupportedArrayFilters.new
      end
    end

    def validate_hint!(connection)
      if op_combiner.has_hint?
        if write_concern && !write_concern.acknowledged?
          raise Error::UnsupportedOption.hint_error(unacknowledged_write: true)
        elsif !connection.features.update_delete_option_validation_enabled?
          raise Error::UnsupportedOption.hint_error
        end
      end
    end
  end
end
