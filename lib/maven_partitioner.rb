require 'nokogiri'
require 'set'

class MavenPartitioner
  POM_XML = 'pom.xml'

  def maven_modules
    return @maven_modules if @maven_modules
    top_level_pom = Nokogiri::XML(File.read(POM_XML))
    @maven_modules = top_level_pom.css('project>modules>module').map { |mvn_module| mvn_module.text }
  end

  def partitions
    maven_modules.map do |mvn_module|
      {
          'type' => 'maven',
          'files' => [mvn_module]
      }
    end
  end

  def incremental_partitions(build)
    modules_to_build = Set.new

    if build.repository.url.end_with?("square/java.git")
      # Build all-java module for all changes in the java repo
      modules_to_build.add("all-java")
    end

    files_changed_method = build.project.main? ? :files_changed_since_last_green : :files_changed_in_branch
    GitBlame.send(files_changed_method, build).each do |file_and_emails|
      module_affected_by_file = file_to_module(file_and_emails[:file])

      if module_affected_by_file.nil?
        if file_and_emails[:file].end_with?(".proto")
          modules_to_build.add("all-protos")
        elsif !file_and_emails[:file].start_with?(".rig")
          return partitions
        end
      else
        modules_to_build.merge(depends_on_map[module_affected_by_file] || Set.new)
      end
    end

    modules_to_build.map do |module_name|
      {
          'type' => 'maven',
          'files' => [module_name]
      }
    end
  end

  def emails_for_commits_causing_failures(java_master_build)
    return [] if java_master_build.build_parts.failed_or_errored.empty?

    failed_modules = java_master_build.build_parts.failed_or_errored.inject(Set.new) do |failed_set, build_part|
      failed_set.add(build_part.paths.first)
    end

    email_and_files = Hash.new { |hash, key| hash[key] = [] }
    GitRepo.inside_copy(java_master_build.repository, java_master_build.ref) do
      GitBlame.files_changed_since_last_green(java_master_build, :fetch_emails => true).each do |file_and_emails|
        file = file_and_emails[:file]
        emails = file_and_emails[:emails]
        module_affected_by_file = file_to_module(file)

        if module_affected_by_file.nil?
          if file.end_with?(".proto")
            if failed_modules.include?("all-protos")
              emails.each { |email| email_and_files[email] << file }
            end
          elsif !file.starts_with?(".rig")
            emails.each { |email| email_and_files[email] << file }
          end
        elsif (set = depends_on_map[module_affected_by_file]) && !set.intersection(failed_modules).empty?
          emails.each { |email| email_and_files[email] << file }
        end
      end
    end

    email_and_files.each_key { |email| email_and_files[email] = email_and_files[email].uniq.sort }

    email_and_files
  end

  def depends_on_map
    return @depends_on_map if @depends_on_map

    module_depends_on_map = {}
    module_dependency_map.each do |mvn_module, dep_set|
      module_depends_on_map[mvn_module] ||= Set.new
      module_depends_on_map[mvn_module].add(mvn_module)
      dep_set.each do |dep|
        module_depends_on_map[dep] ||= Set.new
        module_depends_on_map[dep].add(dep)
        module_depends_on_map[dep].add(mvn_module)
      end
    end

    #HACK do not treat all-protos as a dependency so it does not kill the
    # incremental builds.  Anything that needs a deployable branch will be built separately
    module_depends_on_map['all-protos'] = ["all-protos"].to_set unless module_depends_on_map['all-protos'].nil?

    @depends_on_map = module_depends_on_map
  end

  def module_dependency_map
    return @module_dependency_map if @module_dependency_map

    group_artifact_map = {}

    maven_modules.each do |mvn_module|
      module_pom = Nokogiri::XML(File.read("#{mvn_module}/pom.xml"))
      group_id = module_pom.css('project>groupId').first
      artifact_id = module_pom.css('project>artifactId').first
      next unless group_id && artifact_id
      group_id = group_id.text
      artifact_id = artifact_id.text

      group_artifact_map["#{group_id}:#{artifact_id}"] = "#{mvn_module}"
    end

    module_dependency_map = {}

    maven_modules.each do |mvn_module|
      module_pom = Nokogiri::XML(File.read("#{mvn_module}/pom.xml"))
      module_dependency_map[mvn_module] ||= Set.new

      module_pom.css('project>dependencies>dependency').each do |dep|
        group_id = dep.css('groupId').first.text
        artifact_id = dep.css('artifactId').first.text

        if mod = group_artifact_map["#{group_id}:#{artifact_id}"]
          module_dependency_map[mvn_module].add(mod)
        end
      end
    end

    transitive_dependency_map = {}

    module_dependency_map.keys.each do |mvn_module|
      transitive_dependency_map[mvn_module] = transitive_dependencies(mvn_module, module_dependency_map)
    end

    @module_dependency_map = transitive_dependency_map
  end

  def transitive_dependencies(mvn_module, dependency_map)
    result_set = Set.new
    to_process = [mvn_module]

    while dep_module = to_process.shift
      deps = dependency_map[dep_module].to_a
      to_process += (deps - result_set.to_a)
      result_set << dep_module
    end

    result_set
  end

  def file_to_module(file_path)
    return nil if file_path.start_with?("parents/")
    dir_path = file_path
    while (dir_path = File.dirname(dir_path)) != "."
      if File.exists?("#{dir_path}/pom.xml")
        return dir_path
      end
    end
    nil
  end

  def deployable_modules_map
    deployable_modules_map = {}

    maven_modules.each do |mvn_module|
      module_pom = Nokogiri::XML(File.read("#{mvn_module}/pom.xml"))
      deployable_branch = module_pom.css('project>properties>deployableBranch').first

      if deployable_branch
        deployable_modules_map[mvn_module] = deployable_branch.text
      end
    end

    deployable_modules_map
  end

  def self.deployable_modules_map
    new.deployable_modules_map
  end
end
