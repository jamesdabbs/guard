require 'spec_helper'
require 'guard/plugin'

describe Guard::Interactor do

  describe '.enabled & .enabled=' do
    before do
      @interactor_enabled = described_class.enabled
      described_class.enabled = nil
    end
    after { described_class.enabled = @interactor_enabled }

    it 'returns true by default' do
      expect(described_class.enabled).to be_true
    end

    context 'interactor not enabled' do
      before { described_class.enabled = false }

      it 'returns false' do
        expect(described_class.enabled).to be_false
      end
    end
  end

  describe '.options & .options=' do
    before { described_class.options = nil }

    it 'returns {} by default' do
      expect(described_class.options).to eq({})
    end

    context 'options set to { foo: :bar }' do
      before { described_class.options = { foo: :bar } }

      it 'returns { foo: :bar }' do
        expect(described_class.options).to eq({ foo: :bar })
      end
    end
  end

  describe '.convert_scope' do
    before do
      guard = ::Guard.setup

      stub_const 'Guard::Foo', Class.new(Guard::Plugin)
      stub_const 'Guard::Bar', Class.new(Guard::Plugin)

      @backend_group  = guard.add_group(:backend)
      @frontend_group = guard.add_group(:frontend)
      @foo_guard      = guard.add_plugin(:foo, { group: :backend })
      @bar_guard      = guard.add_plugin(:bar, { group: :frontend })
    end

    it 'returns a group scope' do
      scopes, _ = Guard::Interactor.convert_scope %w(backend)
      expect(scopes).to eq({ groups: [@backend_group], plugins: [] })
      scopes, _ = Guard::Interactor.convert_scope %w(frontend)
      expect(scopes).to eq({ groups: [@frontend_group], plugins: [] })
    end

    it 'returns a plugin scope' do
      scopes, _ = Guard::Interactor.convert_scope %w(foo)
      expect(scopes).to eq({ plugins: [@foo_guard], groups: [] })
      scopes, _ = Guard::Interactor.convert_scope %w(bar)
      expect(scopes).to eq({ plugins: [@bar_guard], groups: [] })
    end

    it 'returns multiple group scopes' do
      scopes, _ = Guard::Interactor.convert_scope %w(backend frontend)
      expect(scopes).to eq({ groups: [@backend_group, @frontend_group], plugins: [] })
    end

    it 'returns multiple plugin scopes' do
      scopes, _ = Guard::Interactor.convert_scope %w(foo bar)
      expect(scopes).to eq({ plugins: [@foo_guard, @bar_guard], groups: [] })
    end

    it 'returns a plugin and group scope' do
      scopes, _ = Guard::Interactor.convert_scope %w(foo backend)
      expect(scopes).to eq({ plugins: [@foo_guard], groups: [@backend_group] })
    end

    it 'returns the unkown scopes' do
      _, unkown = Guard::Interactor.convert_scope %w(unkown scope)
      expect(unkown).to eq %w(unkown scope)
    end
  end

  describe '#start and #stop' do
    before do
      @interactor_enabled = described_class.enabled
      described_class.enabled = nil
      ENV['GUARD_ENV'] = 'interactor_test'
      ::Guard.interactor.stop
    end
    after do
      ::Guard.interactor.stop
      ENV['GUARD_ENV'] = 'test'
      described_class.enabled = @interactor_enabled
    end

    it 'instantiate @thread as an instance of a Thread on #start' do
      ::Guard.interactor.start

      expect(::Guard.interactor.thread).to be_a(Thread)
    end

    it 'sets @thread to nil on #stop' do
      ::Guard.interactor.stop

      expect(::Guard.interactor.thread).to be_nil
    end
  end

end
