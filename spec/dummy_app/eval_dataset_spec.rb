require "rails_helper"
require "yaml"

# The evaluation's expected queries are only worth something if the gem takes them (ADR 0006). An expected answer that the
# validator refuses, or that the compiler cannot run, would score a correct LLM as wrong.
RSpec.describe "evaluation dataset" do
  include ActiveSupport::Testing::TimeHelpers

  EVAL_DIR = Rails.root.join("eval")
  QUESTION_KEYS = %w[id role en fr tags expected also_accepted].freeze

  # held_out.yml is the author's (ADR 0006 D3). Checked like the rest when it exists, and reported by id only.
  def self.splits = %w[dev held_out].select { |split| EVAL_DIR.join("#{split}.yml").exist? }

  def load_split(split) = YAML.safe_load_file(EVAL_DIR.join("#{split}.yml"))
  def queries_of(question) = [ question["expected"], *question["also_accepted"] ]

  it "has the working set" do
    expect(self.class.splits).to include("dev")
    expect(load_split("dev")["questions"].size).to eq(30)
  end

  splits.each do |split|
    describe split do
      let(:data) { load_split(split) }
      let(:questions) { data["questions"] }

      it "gives every question an id, both languages, a role it is allowed to have and nothing else" do
        expect(questions.map { |question| question["id"] }).to all(match(/\A[a-z][a-z0-9_]*\z/))
        expect(questions.map { |question| question["id"] }.uniq.size).to eq(questions.size)

        questions.each do |question|
          expect(question.keys - QUESTION_KEYS).to eq([]), question["id"]
          expect(question.values_at("en", "fr")).to all(be_a(String).and(be_present)), question["id"]
          expect(%w[admin support member]).to include(question.fetch("role", "admin")), question["id"]
        end
      end

      it "expects queries the role's schema and the validator both accept" do
        aggregate_failures do
          questions.each do |question|
            role = question.fetch("role", "admin").to_sym
            schemer = JSONSchemer.schema(DataTeller::SchemaGenerator.for_roles(role))
            validator = DataTeller::QueryValidator.new(DataTeller::Catalog.for(role))

            queries_of(question).each do |query|
              expect(schemer.valid?(query)).to be(true), "#{question['id']}: not valid against the #{role} schema"
              expect(validator.call(query).problems).to eq([]), "#{question['id']}: refused by the validator"
            end
          end
        end
      end

      # On the seeds, as of the dataset's day: the compiler's own refusals (two paths, a series too long) only show here.
      it "expects answers the gem can run on the seeds" do
        load Rails.root.join("db/seeds.rb")
        travel_to(Time.zone.parse("#{data.fetch('today')} 12:00"))
        tenant = Account.find_by!(name: data.fetch("tenant"))
        user_class = Struct.new(:account, :roles)

        aggregate_failures do
          questions.each do |question|
            user = user_class.new(tenant, [ question.fetch("role", "admin").to_sym ])

            queries_of(question).select { |query| query["intent"] == "answer" }.each do |query|
              outcome = DataTeller::QueryRunner.call(query, user: user)
              expect(outcome.status).to eq(:answered), "#{question['id']}: #{outcome.refusal&.reason}"
            end
          end
        end
      ensure
        travel_back
      end
    end
  end
end
