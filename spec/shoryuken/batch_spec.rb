require 'spec_helper'

class TestWorker
  include Shoryuken::Worker
  def perform
  end
end

describe Shoryuken::Batch do
  it 'has a version number' do
    expect(Shoryuken::Batch::VERSION).not_to be nil
  end

  describe '#initialize' do
    subject { described_class }

    it 'creates bid when called without it' do
      expect(subject.new.bid).not_to be_nil
    end

    it 'reuses bid when called with it' do
      batch = subject.new('dayPO5KxuRXXxw')
      expect(batch.bid).to eq('dayPO5KxuRXXxw')
    end
  end

  describe '#description' do
    let(:description) { 'custom description' }
    before { subject.description = description }

    it 'sets descriptions' do
      expect(subject.description).to eq(description)
    end

    it 'persists description' do
      expect(Shoryuken.redis { |r| r.hget("BID-#{subject.bid}", 'description') })
        .to eq(description)
    end
  end

  describe '#callback_queue' do
    let(:callback_queue) { 'custom_queue' }
    before { subject.callback_queue = callback_queue }

    it 'sets callback_queue' do
      expect(subject.callback_queue).to eq(callback_queue)
    end

    it 'persists callback_queue' do
      expect(Shoryuken
             .redis { |r| r.hget("BID-#{subject.bid}", 'callback_queue') })
        .to eq(callback_queue)
    end
  end

  describe '#jobs' do
    it 'throws error if no block given' do
      expect { subject.jobs }.to raise_error Shoryuken::Batch::NoBlockGivenError
    end

    it 'increments to_process (when started)'

    it 'decrements to_process (when finished)'
    # it 'calls process_successful_job to wait for block to finish' do
    #   batch = Shoryuken::Batch.new
    #   expect(Shoryuken::Batch).to receive(:process_successful_job).with(batch.bid)
    #   batch.jobs {}
    # end

    it 'sets Thread.current bid' do
      batch = Shoryuken::Batch.new
      batch.jobs do
        expect(Thread.current[:bid]).to eq(batch)
      end
    end
  end

  describe '#invalidate_all' do
    class InvalidatableJob
      include Shoryuken::Worker

      def perform
        return unless valid_within_batch?
        was_performed
      end

      def was_performed; end
    end

    it 'marks batch in redis as invalidated' do
      batch = Shoryuken::Batch.new
      job = InvalidatableJob.new
      allow(job).to receive(:was_performed)

      batch.invalidate_all
      batch.jobs { job.perform }

      expect(job).not_to have_received(:was_performed)
    end

    context 'nested batches' do
      let(:batch_parent) { Shoryuken::Batch.new }
      let(:batch_child_1) { Shoryuken::Batch.new }
      let(:batch_child_2) { Shoryuken::Batch.new }
      let(:job_of_parent) { InvalidatableJob.new }
      let(:job_of_child_1) { InvalidatableJob.new }
      let(:job_of_child_2) { InvalidatableJob.new }

      before do
        allow(job_of_parent).to receive(:was_performed)
        allow(job_of_child_1).to receive(:was_performed)
        allow(job_of_child_2).to receive(:was_performed)
      end

      it 'invalidates all job if parent batch is marked as invalidated' do
        batch_parent.invalidate_all
        batch_parent.jobs do
          [
            job_of_parent.perform,
            batch_child_1.jobs do
              [
                job_of_child_1.perform,
                batch_child_2.jobs { job_of_child_2.perform }
              ]
            end
          ]
        end

        expect(job_of_parent).not_to have_received(:was_performed)
        expect(job_of_child_1).not_to have_received(:was_performed)
        expect(job_of_child_2).not_to have_received(:was_performed)
      end

      it 'invalidates only requested batch' do
        batch_child_2.invalidate_all
        batch_parent.jobs do
          [
            job_of_parent.perform,
            batch_child_1.jobs do
              [
                job_of_child_1.perform,
                batch_child_2.jobs { job_of_child_2.perform }
              ]
            end
          ]
        end

        expect(job_of_parent).to have_received(:was_performed)
        expect(job_of_child_1).to have_received(:was_performed)
        expect(job_of_child_2).not_to have_received(:was_performed)
      end
    end
  end

  describe '#process_failed_job' do
    let(:batch) { Shoryuken::Batch.new }
    let(:bid) { batch.bid }
    let(:jid) { 'ABCD' }
    before { Shoryuken.redis { |r| r.hset("BID-#{bid}", 'pending', 1) } }

    context 'complete' do
      let(:failed_jid) { 'xxx' }

      it 'tries to call complete callback' do
        expect(Shoryuken::Batch).to receive(:enqueue_callbacks).with(:complete, bid)
        Shoryuken::Batch.process_failed_job(bid, failed_jid)
      end

      it 'add job to failed list' do
        Shoryuken::Batch.process_failed_job(bid, 'failed-job-id')
        Shoryuken::Batch.process_failed_job(bid, failed_jid)
        failed = Shoryuken.redis { |r| r.smembers("BID-#{bid}-failed") }
        expect(failed).to eq(['xxx', 'failed-job-id'])
      end
    end
  end

  describe '#process_successful_job' do
    let(:batch) { Shoryuken::Batch.new }
    let(:bid) { batch.bid }
    let(:jid) { 'ABCD' }
    before { Shoryuken.redis { |r| r.hset("BID-#{bid}", 'pending', 1) } }

    context 'complete' do
      before { batch.on(:complete, Object) }
      # before { batch.increment_job_queue(bid) }
      before { batch.jobs do TestWorker.perform_async end }
      before { Shoryuken::Batch.process_failed_job(bid, 'failed-job-id') }

      it 'tries to call complete callback' do
        expect(Shoryuken::Batch).to receive(:enqueue_callbacks).with(:complete, bid)
        Shoryuken::Batch.process_successful_job(bid, 'failed-job-id')
      end
    end

    context 'success' do
      before { batch.on(:complete, Object) }
      it 'tries to call complete and success callbacks' do
        expect(Shoryuken::Batch).to receive(:enqueue_callbacks).with(:complete, bid)
        expect(Shoryuken::Batch).to receive(:enqueue_callbacks).with(:success, bid)
        Shoryuken::Batch.process_successful_job(bid, jid)
      end

      it 'cleanups redis key' do
        Shoryuken::Batch.process_successful_job(bid, jid)
        expect(Shoryuken.redis { |r| r.get("BID-#{bid}-pending") }.to_i).to eq(0)
      end
    end
  end

  describe '#increment_job_queue' do
    let(:bid) { 'BID' }
    let(:batch) { Shoryuken::Batch.new }

    it 'increments pending' do
      batch.jobs do TestWorker.perform_async end
      pending = Shoryuken.redis { |r| r.hget("BID-#{batch.bid}", 'pending') }
      expect(pending).to eq('1')
    end

    it 'increments total' do
      batch.jobs do TestWorker.perform_async end
      total = Shoryuken.redis { |r| r.hget("BID-#{batch.bid}", 'total') }
      expect(total).to eq('1')
    end
  end

  describe '#enqueue_callbacks' do
    let(:callback) { double('callback') }
    let(:event) { :complete }

    context 'on :success' do
      let(:event) { :success }
      context 'when no callbacks are defined' do
        it 'clears redis keys' do
          batch = Shoryuken::Batch.new
          expect(Shoryuken::Batch).to receive(:cleanup_redis).with(batch.bid)
          Shoryuken::Batch.enqueue_callbacks(event, batch.bid)
        end
      end

      context 'when callbacks are defined' do
        it 'clears redis keys' do
          batch = Shoryuken::Batch.new
          batch.on(event, SampleCallback)
          expect(Shoryuken::Batch).to receive(:cleanup_redis).with(batch.bid)
          Shoryuken::Batch.enqueue_callbacks(event, batch.bid)
        end
      end
    end

    context 'when already called' do
      it 'returns and does not enqueue callbacks' do
        batch = Shoryuken::Batch.new
        batch.on(event, SampleCallback)
        Shoryuken.redis { |r| r.hset("BID-#{batch.bid}", event, true) }

        expect(Shoryuken::Client).not_to receive(:push)
        Shoryuken::Batch.enqueue_callbacks(event, batch.bid)
      end
    end

    context 'when not yet called' do
      context 'when there is no callback' do
        it 'it returns' do
          batch = Shoryuken::Batch.new

          expect(Shoryuken::Client).not_to receive(:push)
          Shoryuken::Batch.enqueue_callbacks(event, batch.bid)
        end
      end

      context 'when callback defined' do
        let(:opts) { { 'a' => 'b' } }

        it 'calls it passing options' do
          batch = Shoryuken::Batch.new
          batch.on(event, SampleCallback, opts)

          expect(Shoryuken::Client).to receive(:push_bulk).with(
            'class' => Shoryuken::Batch::Callback::Worker,
            'args' => [['SampleCallback', event, opts, batch.bid, nil]],
            'queue' => 'default'
          )
          Shoryuken::Batch.enqueue_callbacks(event, batch.bid)
        end
      end

      context 'when multiple callbacks are defined' do
        let(:opts) { { 'a' => 'b' } }
        let(:opts2) { { 'b' => 'a' } }

        it 'enqueues each callback passing their options' do
          batch = Shoryuken::Batch.new
          batch.on(event, SampleCallback, opts)
          batch.on(event, SampleCallback2, opts2)

          expect(Shoryuken::Client).to receive(:push_bulk).with(
            'class' => Shoryuken::Batch::Callback::Worker,
            'args' => [
              ['SampleCallback2', event, opts2, batch.bid, nil],
              ['SampleCallback', event, opts, batch.bid, nil]
            ],
            'queue' => 'default'
          )

          Shoryuken::Batch.enqueue_callbacks(event, batch.bid)
        end
      end
    end
  end
end
