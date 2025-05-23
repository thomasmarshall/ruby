require_relative '../../spec_helper'
require_relative 'fixtures/classes'

describe "Method#source_location" do
  before :each do
    @method = MethodSpecs::SourceLocation.method(:location)
  end

  it "returns an Array" do
    @method.source_location.should be_an_instance_of(Array)
  end

  it "sets the first value to the path of the file in which the method was defined" do
    file = @method.source_location[0]
    file.should be_an_instance_of(String)
    file.should == File.realpath('fixtures/classes.rb', __dir__)
  end

  it "sets the last value to an Integer representing the line on which the method was defined" do
    line = @method.source_location[1]
    line.should be_an_instance_of(Integer)
    line.should == 5
  end

  it "returns the last place the method was defined" do
    MethodSpecs::SourceLocation.method(:redefined).source_location[1].should == 13
  end

  it "returns the location of the original method even if it was aliased" do
    MethodSpecs::SourceLocation.new.method(:aka).source_location[1].should == 17
  end

  it "works for methods defined with a block" do
    line = nil
    klass = Class.new do
      line = __LINE__ + 1
      define_method(:f) { }
    end

    method = klass.new.method(:f)
    method.source_location[0].should =~ /#{__FILE__}/
    method.source_location[1].should == line
  end

  it "works for methods defined with a Method" do
    line = nil
    klass = Class.new do
      line = __LINE__ + 1
      def f
      end
      define_method :g, new.method(:f)
    end

    method = klass.new.method(:g)
    method.source_location[0].should =~ /#{__FILE__}/
    method.source_location[1].should == line
  end

  it "works for methods defined with an UnboundMethod" do
    line = nil
    klass = Class.new do
      line = __LINE__ + 1
      def f
      end
      define_method :g, instance_method(:f)
    end

    method = klass.new.method(:g)
    method.source_location[0].should =~ /#{__FILE__}/
    method.source_location[1].should == line
  end

  it "works for methods whose visibility has been overridden in a subclass" do
    line = nil
    superclass = Class.new do
      line = __LINE__ + 1
      def f
      end
    end
    subclass = Class.new(superclass) do
      private :f
    end

    method = subclass.new.method(:f)
    method.source_location[0].should =~ /#{__FILE__}/
    method.source_location[1].should == line
  end

  it "works for core methods where it returns nil or <internal:" do
    loc = method(:__id__).source_location
    if loc == nil
      loc.should == nil
    else
      loc[0].should.start_with?('<internal:')
      loc[1].should be_kind_of(Integer)
    end

    loc = method(:tap).source_location
    if loc == nil
      loc.should == nil
    else
      loc[0].should.start_with?('<internal:')
      loc[1].should be_kind_of(Integer)
    end
  end

  it "works for eval with a given line" do
    c = Class.new do
      eval('def self.m; end', nil, "foo", 100)
    end
    location = c.method(:m).source_location
    ruby_version_is(""..."3.5") do
      location.should == ["foo", 100]
    end
    ruby_version_is("3.5") do
      location.should == ["foo", 100, 0, 100, 15]
    end
  end

  describe "for a Method generated by respond_to_missing?" do
    it "returns nil" do
      m = MethodSpecs::Methods.new
      m.method(:handled_via_method_missing).source_location.should be_nil
    end
  end
end
