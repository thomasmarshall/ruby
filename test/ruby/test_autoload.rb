# frozen_string_literal: false
require 'test/unit'
require 'tempfile'

class TestAutoload < Test::Unit::TestCase
  def test_autoload_so
    # Date is always available, unless excluded intentionally.
    assert_in_out_err([], <<-INPUT, [], [])
    autoload :Date, "date"
    begin Date; rescue LoadError; end
    INPUT
  end

  def test_non_realpath_in_loadpath
    require 'tmpdir'
    tmpdir = Dir.mktmpdir('autoload')
    tmpdirs = [tmpdir]
    tmpdirs.unshift(tmpdir + '/foo')
    Dir.mkdir(tmpdirs[0])
    tmpfiles = [tmpdir + '/foo.rb', tmpdir + '/foo/bar.rb']
    open(tmpfiles[0] , 'w') do |f|
      f.puts <<-INPUT
$:.unshift(File.expand_path('..', __FILE__)+'/./foo')
module Foo
  autoload :Bar, 'bar'
end
p Foo::Bar
      INPUT
    end
    open(tmpfiles[1], 'w') do |f|
      f.puts 'class Foo::Bar; end'
    end
    assert_in_out_err([tmpfiles[0]], "", ["Foo::Bar"], [])
  ensure
    File.unlink(*tmpfiles) rescue nil if tmpfiles
    tmpdirs.each {|dir| Dir.rmdir(dir)}
  end

  def test_autoload_p
    bug4565 = '[ruby-core:35679]'

    require 'tmpdir'
    Dir.mktmpdir('autoload') {|tmpdir|
      tmpfile = tmpdir + '/foo.rb'
      tmpfile2 = tmpdir + '/bar.rb'
      a = Module.new do
        autoload :X, tmpfile
        autoload :Y, tmpfile2
      end
      b = Module.new do
        include a
      end
      assert_equal(true, a.const_defined?(:X))
      assert_equal(true, b.const_defined?(:X))
      assert_equal(tmpfile, a.autoload?(:X), bug4565)
      assert_equal(tmpfile, b.autoload?(:X), bug4565)
      assert_equal(tmpfile, a.autoload?(:X, false))
      assert_equal(tmpfile, a.autoload?(:X, nil))
      assert_nil(b.autoload?(:X, false))
      assert_nil(b.autoload?(:X, nil))
      assert_equal(true, a.const_defined?("Y"))
      assert_equal(true, b.const_defined?("Y"))
      assert_equal(tmpfile2, a.autoload?("Y"))
      assert_equal(tmpfile2, b.autoload?("Y"))
    }
  end

  def test_autoload_p_with_static_extensions
    require 'rbconfig'
    omit unless RbConfig::CONFIG['EXTSTATIC'] == 'static'
    begin
      require 'fcntl.so'
    rescue LoadError
      omit('fcntl not included in the build')
    end

    assert_separately(['--disable-all'], <<~RUBY)
      autoload :Fcntl, 'fcntl.so'

      assert_equal('fcntl.so', autoload?(:Fcntl))
      assert(Object.const_defined?(:Fcntl))
      assert_equal('constant', defined?(Fcntl), '[Bug #19115]')
    RUBY
  end

  def test_autoload_with_unqualified_file_name # [ruby-core:69206]
    Object.send(:remove_const, :A) if Object.const_defined?(:A)

    lp = $LOAD_PATH.dup
    lf = $LOADED_FEATURES.dup

    Dir.mktmpdir('autoload') { |tmpdir|
      $LOAD_PATH << tmpdir

      Dir.chdir(tmpdir) do
        eval <<-END
          class ::Object
            module A
              autoload :C, 'test-ruby-core-69206'
            end
          end
        END

        File.write("test-ruby-core-69206.rb", 'module A; class C; end; end')
        assert_kind_of Class, ::A::C
      end
    }
  ensure
    $LOAD_PATH.replace lp
    $LOADED_FEATURES.replace lf
    Object.send(:remove_const, :A) if Object.const_defined?(:A)
  end

  def test_require_explicit
    Tempfile.create(['autoload', '.rb']) {|file|
      file.puts 'class Object; AutoloadTest = 1; end'
      file.close
      add_autoload(file.path)
      begin
        assert_nothing_raised do
          assert(require file.path)
          assert_equal(1, ::AutoloadTest)
        end
      ensure
        remove_autoload_constant
      end
    }
  end

  def test_threaded_accessing_constant
    # Suppress "warning: loading in progress, circular require considered harmful"
    EnvUtil.default_warning {
      Tempfile.create(['autoload', '.rb']) {|file|
        file.puts 'sleep 0.5; class AutoloadTest; X = 1; end'
        file.close
        add_autoload(file.path)
        begin
          assert_nothing_raised do
            t1 = Thread.new { ::AutoloadTest::X }
            t2 = Thread.new { ::AutoloadTest::X }
            [t1, t2].each(&:join)
          end
        ensure
          remove_autoload_constant
        end
      }
    }
  end

  def test_threaded_accessing_inner_constant
    # Suppress "warning: loading in progress, circular require considered harmful"
    EnvUtil.default_warning {
      Tempfile.create(['autoload', '.rb']) {|file|
        file.puts 'class AutoloadTest; sleep 0.5; X = 1; end'
        file.close
        add_autoload(file.path)
        begin
          assert_nothing_raised do
            t1 = Thread.new { ::AutoloadTest::X }
            t2 = Thread.new { ::AutoloadTest::X }
            [t1, t2].each(&:join)
          end
        ensure
          remove_autoload_constant
        end
      }
    }
  end

  def test_nameerror_when_autoload_did_not_define_the_constant
    verbose_bak, $VERBOSE = $VERBOSE, nil
    Tempfile.create(['autoload', '.rb']) {|file|
      file.puts ''
      file.close
      add_autoload(file.path)
      begin
        assert_raise(NameError) do
          AutoloadTest
        end
      ensure
        remove_autoload_constant
      end
    }
  ensure
    $VERBOSE = verbose_bak
  end

  def test_override_autoload
    Tempfile.create(['autoload', '.rb']) {|file|
      file.puts ''
      file.close
      add_autoload(file.path)
      begin
        eval %q(class AutoloadTest; end)
        assert_equal(Class, AutoloadTest.class)
      ensure
        remove_autoload_constant
      end
    }
  end

  def test_override_while_autoloading
    Tempfile.create(['autoload', '.rb']) {|file|
      file.puts 'class AutoloadTest; sleep 0.5; end'
      file.close
      add_autoload(file.path)
      begin
        # while autoloading...
        t = Thread.new { AutoloadTest }
        sleep 0.1
        # override it
        EnvUtil.suppress_warning {
          eval %q(AutoloadTest = 1)
        }
        t.join
        assert_equal(1, AutoloadTest)
      ensure
        remove_autoload_constant
      end
    }
  end

  def ruby_impl_require
    Kernel.module_eval do
      alias old_require require
    end
    Namespace.module_eval do
      alias old_require require
    end
    called_with = []
    Kernel.send :define_method, :require do |path|
      called_with << path
      old_require path
    end
    Namespace.send :define_method, :require do |path|
      called_with << path
      old_require path
    end
    yield called_with
  ensure
    Kernel.module_eval do
      undef require
      alias require old_require
      undef old_require
    end
    Namespace.module_eval do
      undef require
      alias require old_require
      undef old_require
    end
  end

  def test_require_implemented_in_ruby_is_called
    ruby_impl_require do |called_with|
      Tempfile.create(['autoload', '.rb']) {|file|
        file.puts 'class AutoloadTest; end'
        file.close
        add_autoload(file.path)
        begin
          assert(Object::AutoloadTest)
        ensure
          remove_autoload_constant
        end
        # .dup to prevent breaking called_with by autoloading pp, etc
        assert_equal [file.path], called_with.dup
      }
    end
  end

  def test_autoload_while_autoloading
    ruby_impl_require do |called_with|
      Tempfile.create(%w(a .rb)) do |a|
        Tempfile.create(%w(b .rb)) do |b|
          a.puts "require '#{b.path}'; class AutoloadTest; end"
          b.puts "class AutoloadTest; module B; end; end"
          [a, b].each(&:flush)
          add_autoload(a.path)
          begin
            assert(Object::AutoloadTest)
          ensure
            remove_autoload_constant
          end
          # .dup to prevent breaking called_with by autoloading pp, etc
          assert_equal [a.path, b.path], called_with.dup
        end
      end
    end
  end

  def test_bug_13526
    # Skip this on macOS 10.13 because of the following error:
    # http://rubyci.s3.amazonaws.com/osx1013/ruby-master/log/20231011T014505Z.fail.html.gz
    require "rbconfig"

    script = File.join(__dir__, 'bug-13526.rb')
    assert_ruby_status([script], '', '[ruby-core:81016] [Bug #13526]')
  end

  def test_autoload_private_constant
    Dir.mktmpdir('autoload') do |tmpdir|
      File.write(tmpdir+"/test-bug-14469.rb", "#{<<~"begin;"}\n#{<<~'end;'}")
      begin;
        class AutoloadTest
          ZZZ = :ZZZ
          private_constant :ZZZ
        end
      end;
      assert_separately(%W[-I #{tmpdir}], "#{<<-"begin;"}\n#{<<-'end;'}")
      bug = '[ruby-core:85516] [Bug #14469]'
      begin;
        class AutoloadTest
          autoload :ZZZ, "test-bug-14469.rb"
        end
        assert_raise(NameError, bug) {AutoloadTest::ZZZ}
      end;
    end
  end

  def test_autoload_deprecate_constant
    Dir.mktmpdir('autoload') do |tmpdir|
      File.write(tmpdir+"/test-bug-14469.rb", "#{<<~"begin;"}\n#{<<~'end;'}")
      begin;
        class AutoloadTest
          ZZZ = :ZZZ
          deprecate_constant :ZZZ
        end
      end;
      assert_separately(%W[-I #{tmpdir}], "#{<<-"begin;"}\n#{<<-'end;'}")
      bug = '[ruby-core:85516] [Bug #14469]'
      begin;
        class AutoloadTest
          autoload :ZZZ, "test-bug-14469.rb"
        end
        assert_warning(/ZZZ is deprecated/, bug) {AutoloadTest::ZZZ}
      end;
    end
  end

  def test_autoload_private_constant_before_autoload
    Dir.mktmpdir('autoload') do |tmpdir|
      File.write(tmpdir+"/test-bug-11055.rb", "#{<<~"begin;"}\n#{<<~'end;'}")
      begin;
        class AutoloadTest
          ZZZ = :ZZZ
        end
      end;
      assert_separately(%W[-I #{tmpdir}], "#{<<-"begin;"}\n#{<<-'end;'}")
      bug = '[Bug #11055]'
      begin;
        class AutoloadTest
          autoload :ZZZ, "test-bug-11055.rb"
          private_constant :ZZZ
          ZZZ
        end
        assert_raise(NameError, bug) {AutoloadTest::ZZZ}
      end;
      assert_separately(%W[-I #{tmpdir}], "#{<<-"begin;"}\n#{<<-'end;'}")
      bug = '[Bug #11055]'
      begin;
        class AutoloadTest
          autoload :ZZZ, "test-bug-11055.rb"
          private_constant :ZZZ
        end
        assert_raise(NameError, bug) {AutoloadTest::ZZZ}
      end;
    end
  end

  def test_autoload_deprecate_constant_before_autoload
    Dir.mktmpdir('autoload') do |tmpdir|
      File.write(tmpdir+"/test-bug-11055.rb", "#{<<~"begin;"}\n#{<<~'end;'}")
      begin;
        class AutoloadTest
          ZZZ = :ZZZ
        end
      end;
      assert_separately(%W[-I #{tmpdir}], "#{<<-"begin;"}\n#{<<-'end;'}")
      bug = '[Bug #11055]'
      begin;
        class AutoloadTest
          autoload :ZZZ, "test-bug-11055.rb"
          deprecate_constant :ZZZ
        end
        assert_warning(/ZZZ is deprecated/, bug) {class AutoloadTest; ZZZ; end}
        assert_warning(/ZZZ is deprecated/, bug) {AutoloadTest::ZZZ}
      end;
      assert_separately(%W[-I #{tmpdir}], "#{<<-"begin;"}\n#{<<-'end;'}")
      bug = '[Bug #11055]'
      begin;
        class AutoloadTest
          autoload :ZZZ, "test-bug-11055.rb"
          deprecate_constant :ZZZ
        end
        assert_warning(/ZZZ is deprecated/, bug) {AutoloadTest::ZZZ}
      end;
    end
  end

  def test_autoload_fork
    EnvUtil.default_warning do
      Tempfile.create(['autoload', '.rb']) {|file|
        file.puts 'sleep 0.3; class AutoloadTest; end'
        file.close
        add_autoload(file.path)
        begin
          thrs = []
          3.times do
            thrs << Thread.new { AutoloadTest && nil }
            thrs << Thread.new { fork { AutoloadTest } }
          end
          thrs.each(&:join)
          thrs.each do |th|
            pid = th.value or next
            _, status = Process.waitpid2(pid)
            assert_predicate status, :success?
          end
        ensure
          remove_autoload_constant
          assert_nil $!, '[ruby-core:86410] [Bug #14634]'
        end
      }
    end
  end if Process.respond_to?(:fork)

  def test_autoload_same_file
    Dir.mktmpdir('autoload') do |tmpdir|
      File.write("#{tmpdir}/test-bug-14742.rb", "#{<<~'begin;'}\n#{<<~'end;'}")
      begin;
        module Foo; end
        module Bar; end
      end;
      3.times do # timing-dependent, needs a few times to hit [Bug #14742]
        assert_separately(%W[-I #{tmpdir}], "#{<<-'begin;'}\n#{<<-'end;'}")
        begin;
          autoload :Foo, 'test-bug-14742'
          autoload :Bar, 'test-bug-14742'
          t1 = Thread.new do Foo end
          t2 = Thread.new do Bar end
          t1.join
          t2.join
          bug = '[ruby-core:86935] [Bug #14742]'
          assert_instance_of Module, t1.value, bug
          assert_instance_of Module, t2.value, bug
        end;
      end
    end
  end

  def test_autoload_same_file_with_raise
    Dir.mktmpdir('autoload') do |tmpdir|
      File.write("#{tmpdir}/test-bug-16177.rb", "#{<<~'begin;'}\n#{<<~'end;'}")
      begin;
        raise '[ruby-core:95055] [Bug #16177]'
      end;
      assert_raise(RuntimeError, '[ruby-core:95055] [Bug #16177]') do
        assert_separately(%W[-I #{tmpdir}], "#{<<-'begin;'}\n#{<<-'end;'}")
        begin;
          autoload :Foo, 'test-bug-16177'
          autoload :Bar, 'test-bug-16177'
          t1 = Thread.new do Foo end
          t2 = Thread.new do Bar end
          t1.join
          t2.join
        end;
      end
    end
  end

  def test_source_location
    bug = "Bug16764"
    Dir.mktmpdir('autoload') do |tmpdir|
      path = "#{tmpdir}/test-#{bug}.rb"
      File.write(path, "C::#{bug} = __FILE__\n")
      assert_separately(%W[-I #{tmpdir}], "#{<<-"begin;"}\n#{<<-"end;"}")
      begin;
        class C; end
        C.autoload(:Bug16764, #{path.dump})
        assert_equal [__FILE__, __LINE__-1], C.const_source_location(#{bug.dump})
        assert_equal #{path.dump}, C.const_get(#{bug.dump})
        assert_equal [#{path.dump}, 1], C.const_source_location(#{bug.dump})
      end;
    end
  end

  def test_source_location_after_require
    bug = "Bug18624"
    Dir.mktmpdir('autoload') do |tmpdir|
      path = "#{tmpdir}/test-#{bug}.rb"
      File.write(path, "C::#{bug} = __FILE__\n")
      assert_separately(%W[-I #{tmpdir}], "#{<<-"begin;"}\n#{<<-"end;"}")
      begin;
        class C; end
        C.autoload(:Bug18624, #{path.dump})
        require #{path.dump}
        assert_equal [#{path.dump}, 1], C.const_source_location(#{bug.dump})
        assert_equal #{path.dump}, C.const_get(#{bug.dump})
        assert_equal [#{path.dump}, 1], C.const_source_location(#{bug.dump})
      end;
    end
  end

  def test_no_memory_leak
    assert_no_memory_leak([], '', "#{<<~"begin;"}\n#{<<~'end;'}", 'many autoloads', timeout: 60)
    begin;
      200000.times do |i|
        m = Module.new
        m.instance_eval do
          autoload :Foo, 'x'
          autoload :Bar, i.to_s
        end
      end
    end;
  end

  def test_autoload_after_failed_and_removed_from_loaded_features
    Dir.mktmpdir('autoload') do |tmpdir|
      autoload_path = File.join(tmpdir, "test-bug-15790.rb")
      File.write(autoload_path, '')

      assert_separately(%W[-I #{tmpdir}], <<-RUBY)
        $VERBOSE = nil
        path = #{File.realpath(autoload_path).inspect}
        autoload :X, path
        assert_equal(path, Object.autoload?(:X))

        assert_raise(NameError){X}
        assert_nil(Object.autoload?(:X))
        assert_equal(false, Object.const_defined?(:X))

        $LOADED_FEATURES.delete(path)
        assert_equal(false, Object.const_defined?(:X))
        assert_nil(Object.autoload?(:X))

        assert_raise(NameError){X}
        assert_equal(false, Object.const_defined?(:X))
        assert_nil(Object.autoload?(:X))
      RUBY
    end
  end

  def add_autoload(path)
    (@autoload_paths ||= []) << path
    ::Object.class_eval {autoload(:AutoloadTest, path)}
  end

  def remove_autoload_constant
    $".replace($" - @autoload_paths)
    ::Object.class_eval {remove_const(:AutoloadTest)} if defined? Object::AutoloadTest
    TestAutoload.class_eval {remove_const(:AutoloadTest)} if defined? TestAutoload::AutoloadTest
  end

  def test_autoload_module_gc
    Dir.mktmpdir('autoload') do |tmpdir|
      autoload_path = File.join(tmpdir, "autoload_module_gc.rb")
      File.write(autoload_path, "X = 1; Y = 2;")

      x = Module.new
      x.autoload :X, "./feature.rb"

      1000.times do
        y = Module.new
        y.autoload :Y, "./feature.rb"
      end

      x = y = nil

      # Ensure the internal data structures are cleaned up correctly / don't crash:
      GC.start
    end
  end

  def test_autoload_parallel_race
    Dir.mktmpdir('autoload') do |tmpdir|
      autoload_path = File.join(tmpdir, "autoload_parallel_race.rb")
      File.write(autoload_path, 'module Foo; end; module Bar; end')

      assert_separately([], <<-RUBY, timeout: 100)
        autoload_path = #{File.realpath(autoload_path).inspect}

        # This should work with no errors or failures.
        1000.times do
          autoload :Foo, autoload_path
          autoload :Bar, autoload_path

          t1 = Thread.new {Foo}
          t2 = Thread.new {Bar}

          t1.join
          GC.start # force GC.
          t2.join

          Object.send(:remove_const, :Foo)
          Object.send(:remove_const, :Bar)

          $LOADED_FEATURES.delete(autoload_path)
        end
      RUBY
    end
  end

  def test_autoload_parent_namespace
    Dir.mktmpdir('autoload') do |tmpdir|
      autoload_path = File.join(tmpdir, "some_const.rb")
      File.write(autoload_path, 'class SomeConst; end')

      assert_separately(%W[-I #{tmpdir}], <<-RUBY)
        module SomeNamespace
          autoload :SomeConst, #{File.realpath(autoload_path).inspect}
          assert_warning(%r{/some_const\.rb to define SomeNamespace::SomeConst but it didn't}) do
            assert_not_nil SomeConst
          end
        end
      RUBY
    end
  end
end
