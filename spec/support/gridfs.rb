# Copyright (C) 2014-2015 MongoDB, Inc.
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

# Matcher for determining if the results of the opeartion match the
# test's expected results.
#
# @since 2.0.0

# Matcher for determining if the collection's data matches the
# test's expected collection data.
#
# @since 2.1.0

RSpec::Matchers.define :completes_successfully do |test|

  match do |actual|
    actual == test.expected_result || test.expected_result.nil?
  end
end

RSpec::Matchers.define :match_chunks_collection do |expected|

  match do |actual|
    return true if expected.nil?
    if expected.find.to_a.empty?
      actual.find.to_a.empty?
    else
      actual.find.all? do |doc|
        if matching_doc = expected.find(files_id: doc['files_id'], n: doc['n']).first
          matching_doc.all? do |k, v|
            doc[k] == v || k == '_id'
          end
        else
          false
        end
      end
    end
  end
end

RSpec::Matchers.define :match_error do |error|

  match do |actual|

    mapping = {
      'FileNotFound' => Mongo::Error::FileNotFound,
      'ChunkIsMissing' => Mongo::Error::MissingFileChunk,
      'ChunkIsWrongSize' => Mongo::Error::UnexpectedChunkLength,
      'ExtraChunk' => Mongo::Error::ExtraFileChunk
    }
    mapping[error] == actual.class
  end
end

RSpec::Matchers.define :match_files_collection do |expected|

  match do |actual|
    return true if expected.nil?
    actual.find.all? do |doc|
      if matching_doc = expected.find(_id: doc['_id']).first
        matching_doc.all? do |k, v|
          doc[k] == v
        end
      else
        false
      end
    end
  end
end


module Mongo
  module GridFS

    # Represents a GridFS specification test.
    #
    # @since 2.0.0
    class Spec

      # @return [ String ] description The spec description.
      #
      # @since 2.0.0
      attr_reader :description

      # Instantiate the new spec.
      #
      # @example Create the spec.
      #   Spec.new(file)
      #
      # @param [ String ] file The name of the file.
      #
      # @since 2.1.0
      def initialize(file)
        @spec = YAML.load(ERB.new(File.new(file).read).result)
        @description = File.basename(file)
        @data = @spec['data']
      end

      # Get a list of CRUDTests for each test definition.
      #
      # @example Get the list of CRUDTests.
      #   spec.tests
      #
      # @return [ Array<CRUDTest> ] The list of CRUDTests.
      #
      # @since 2.1.0
      def tests
        @tests ||= @spec['tests'].collect do |test|
          Mongo::GridFS::GridFSTest.new(@data, test)
        end
      end
    end

    module Convertible
    
      def limit(int)
        int == 0 ? 'many' : 'one'
      end

      def convert__id(v, opts = {})
        to_oid(v, opts[:id])
      end

      def convert_uploadDate(v, opts = {})
        upload_date
      end

      def convert_files_id(v, opts = {})
        to_oid(v, opts[:files_id])
      end

      def convert_data(v, opts = {})
        v.is_a?(BSON::Binary) ? v : BSON::Binary.new(to_hex(v['$hex'], opts), :generic)
      end

      def transform_docs(docs, opts = {})
        # cannot alter original list
        docs.collect do |doc|
          doc.each do |k, v|
            doc[k] = send("convert_#{k}", v, opts) if respond_to?("convert_#{k}")
          end
          doc
        end
      end
    
      def to_hex(string, opts = {})
        [ string ].pack('H*')
      end
    
      def to_oid(value, id = nil)
        if id
          id
        elsif value.is_a?(BSON::ObjectId)
          value
        elsif value['$oid']
          BSON::ObjectId.from_string(value['$oid'])
        else          
          BSON::ObjectId.new
        end
      end

      def options
        @act['arguments']['options'].reduce({}) do |opts, (k, v)|
          opts.merge!(chunk_size: v) if k == "chunkSizeBytes"
          opts.merge!(upload_date: upload_date)
          opts.merge!(content_type: v) if k == "contentType"
          opts.merge!(metadata: v) if k == "metadata"
          opts
        end
      end
    end

    # Represents a single GridFS test.
    #
    # @since 2.1.0
    class GridFSTest
      include Convertible
      extend Forwardable

      def_delegators :@operation, :expected_files_collection, :expected_chunks_collection

      # The test description.
      #
      # @return [ String ] description The test description.
      #
      # @since 2.1.0
      attr_reader :description
      attr_reader :upload_date

      # Instantiate the new GridFSTest.
      #
      # @example Create the test.
      #   GridFSTest.new(data, test)
      #
      # @param [ Array<Hash> ] data The documents the files and chunks
      # collections must have before the test runs.
      # @param [ Hash ] test The test specification.
      #
      # @since 2.0.0
      def initialize(data, test)
        @data = data
        @description = test['description']
        @upload_date = Time.now
        if test['assert']['error']
          @operation = UnsuccessfulOp.new(self, test)
        else
          @operation = SuccessfulOp.new(self, test)
        end
      end

      def expected_result
        @operation.expected_result
      end

      def error?
        @operation.is_a?(UnsuccessfulOp)
      end

      def assert_data?
        @operation.assert['data']
      end

      def result
        @operation.result
      end

      def error
        @operation.error
      end

      def run(fs)
        setup(fs)
        @operation.run(fs)
      end

      def match_result?(result)
        @operation.match_result?(result)
      end

      def clear_collections(fs)
        fs.files_collection.delete_many
        fs.chunks_collection.delete_many
        @operation.clear_collections(fs)
      end

      private

      def setup(fs)
        insert_pre_data(fs)
        @operation.arrange(fs)
      end

      def files_data
        @files_data ||= transform_docs(@data['files'])
      end

      def chunks_data
        @chunks_data ||= transform_docs(@data['chunks'])
      end

      def insert_pre_data(fs)
        unless files_data.empty?
          fs.files_collection.insert_many(files_data)
          fs.database['expected.files'].insert_many(files_data)
        end
        unless chunks_data.empty?
          fs.chunks_collection.insert_many(chunks_data)
          fs.database['expected.chunks'].insert_many(chunks_data)
        end
      end

      module Operable
        extend Forwardable

        def_delegators :@test, :upload_date
  
        attr_reader :op
        attr_reader :assert
        attr_reader :result
        attr_reader :expected_files_collection
        attr_reader :expected_chunks_collection
    
        def initialize(test, spec)
          @test = test
          @arrange = spec['arrange']
          @act = spec['act']
          @op = @act['operation']
          @arguments = @act['arguments']
          @assert = spec['assert']
        end
    
        def prepare_expected_collections(fs)
          if @assert['data']
            @assert['data'].each do |data|
              op = "#{data.keys.first}_exp_data"
              send(op, fs, data)
            end
          end
        end

        def insert_exp_data(fs, data)
          coll = fs.database[data['insert']]
          if coll.name =~ /.files/
            opts = { id: @result }
          else
            opts = { files_id: @result }
          end
          coll.insert_many(transform_docs(data['documents'], opts))
        end
    
        def delete_exp_data(fs, data)
          coll = fs.database[data['delete']]
          data['deletes'].each do |del|
            id = del['q'].keys.first
            coll.find(id => to_oid(del['q'][id])).send("delete_#{limit(del['limit'])}")
          end
        end

        def update_exp_data(fs, data)
          coll = fs.database[data['update']]
          data['updates'].each do |update|
            sel = update['q'].merge('files_id' => to_oid(update['q']['files_id']))
            data = BSON::Binary.new(to_hex(update['u']['$set']['data']['$hex']), :generic)
            u = update['u'].merge('$set' => { 'data' => data })
            coll.find(sel).update_one(u)
          end
        end

        def arrange(fs)
          if @arrange
            @arrange['data'].each do |data|
              send("#{data.keys.first}_exp_data", fs, data)
            end
          end
        end
    
        def delete(fs)
          fs.delete(to_oid(@arguments['id']))
        end

        def filename
          @arguments['filename']
        end

        def upload(fs)
          io = StringIO.new(to_hex(@act['arguments']['source']['$hex']))
          fs.upload_from_stream(filename, io, options)
        end

        def download(fs)
          io = StringIO.new.set_encoding(BSON::BINARY)
          fs.download_to_stream(to_oid(@arguments['id']), io)
          io.string
        end

        def run(fs)
          @expected_files_collection = fs.database['expected.files']
          @expected_chunks_collection = fs.database['expected.chunks']
          act(fs)
          prepare_expected_collections(fs)
          result
        end

        def error
          @assert['error']
        end
    
        def clear_collections(fs)
          @manipulated_collections.each { |col| col.delete_many }
        end
      end

      class SuccessfulOp
        include Convertible
        include GridFSTest::Operable

        def expected_result
          if @assert['result'] == '&result'
            @result
          elsif @assert['result'] != 'void'
            to_hex(@assert['result']['$hex'])
          end
        end

        def act(fs)
          @result = send(op, fs)
        end
  
        def match_result?(result)
          result == @files_id
        end
      end
  
      class UnsuccessfulOp
        include Convertible
        include GridFSTest::Operable
  
        def act(fs)
          begin
            send(op, fs)
          rescue => ex
            @result = ex
          end
        end
      end
    end
  end
end
