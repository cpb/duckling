# Renders a stage's ERB template. Templates get a plain Hash of locals and
# a `partial` helper, and nothing else — no access to the calling binding,
# so a template cannot quietly depend on a stage's internals.

require "erb"
require "ostruct"

module Plan
  class Renderer
    PARTIALS = File.join(__dir__, "partials")

    def initialize(template_dir)
      @template_dir = template_dir
    end

    def render(name, **locals)
      path = File.join(@template_dir, name)
      abort "Template not found: #{path}" unless File.exist?(path)
      Scope.new(self, locals).render(File.read(path), path)
    end

    # Partials are shared across stages and live in stage000-shared/partials.
    # Named with a leading underscore, the way Rails partials are, so a
    # directory listing separates them from a stage's own templates.
    def partial(name, **locals)
      path = File.join(PARTIALS, "_#{name}.md.erb")
      abort "Partial not found: #{path}" unless File.exist?(path)
      Scope.new(self, locals).render(File.read(path), path)
    end

    class Scope
      def initialize(renderer, locals)
        @renderer = renderer
        locals.each { |k, v| define_singleton_method(k) { v } }
        @locals = locals
      end

      def partial(name, **locals) = @renderer.partial(name, **@locals.merge(locals))

      # Markdown tables break on an unescaped pipe, and rule names are full
      # of them ("from|since|after <time>").
      def cell(text) = text.to_s.gsub("|", "\\|")

      def render(source, path)
        ERB.new(source, trim_mode: "-").result(binding)
      rescue NameError => e
        abort "#{path}: #{e.message}\nLocals available: #{@locals.keys.sort.join(", ")}"
      end
    end
  end
end
