project('dxml', 'd',
    meson_version : '>=0.56',

    license: 'BSL-1.0',
    version: '0.1'
)

pkgc = import('pkgconfig')
dc = meson.get_compiler('d')

#
# Sources
#

d_source_dir = meson.current_source_dir() / 'source'
root_inc_dir = include_directories('source')

# automatically collect D sources
d_src_cmd = run_command('find', d_source_dir, '-type', 'f', '-name', '*.d', check: false)
if d_src_cmd.returncode() == 0
    source_files = d_src_cmd.stdout().strip().split('\n')
else
    error('Failed to find D source files')
endif

#
# Library
#
dxml_lib = static_library('dxml',
    [source_files],
    include_directories: [root_inc_dir],
    install: true,
)

install_subdir(d_source_dir / 'dxml', install_dir: 'include/d/dxml/')

pkgc.generate(dxml_lib,
    name: 'dxml',
    subdirs: 'd/dxml',
    version: meson.project_version(),
    description: 'An XML parsing library written in D.'
)

# for use by others which embed this as subproject
dxml_dep = declare_dependency(
    link_with: [dxml_lib],
    include_directories: [root_inc_dir]
)

#
# Tests
#
if dc.get_id() == 'gcc'
    test_link_args = []
    test_main_file = configure_file(capture: true,
                                    command: ['echo', 'int main(string[] args) { return 0; }'],
                                    output: 'unittest_main.d'
	)
else
    test_link_args = ['-main']
    test_main_file = []
endif

dxml_test_exe = executable('dxml_test',
    [source_files, test_main_file],
    include_directories: [root_inc_dir],
    d_unittest: true,
    link_args: test_link_args
)
test('dxml-test',
      dxml_test_exe,
)
