defmodule LightningWeb.WorkflowLive.EditTest do
  use LightningWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Lightning.WorkflowLive.Helpers
  import Lightning.WorkflowsFixtures
  import Lightning.JobsFixtures
  import Lightning.Factories
  import Ecto.Query

  alias Lightning.Helpers
  alias Lightning.Workflows.Snapshot
  alias Lightning.Workflows
  alias Lightning.Repo
  alias LightningWeb.CredentialLiveHelpers
  alias Lightning.Workflows.Workflow

  setup :register_and_log_in_user
  setup :create_project_for_current_user

  describe "New credential from project context " do
    setup %{project: project} do
      %{job: job} = workflow_job_fixture(project_id: project.id)
      workflow = Repo.get(Workflow, job.workflow_id)
      {:ok, snapshot} = Workflows.Snapshot.get_or_create_latest_for(workflow)
      %{job: job, workflow: workflow, snapshot: snapshot}
    end

    test "open credential modal from the job inspector (edit_workflow)", %{
      conn: conn,
      project: project,
      job: job,
      workflow: workflow
    } do
      {:ok, view, _html} =
        live(
          conn,
          ~p"/projects/#{project.id}/w/#{job.workflow_id}?s=#{job.id}&v=#{workflow.lock_version}"
        )

      assert has_element?(view, "#job-pane-#{job.id}")

      assert has_element?(view, "#credential-schema-picker")
      view |> CredentialLiveHelpers.select_credential_type("http")
      view |> CredentialLiveHelpers.click_continue()

      refute has_element?(view, "#project_list")
    end

    test "create new credential from job inspector and update the job form", %{
      conn: conn,
      project: project,
      job: job,
      workflow: workflow
    } do
      {:ok, view, _html} =
        live(
          conn,
          ~p"/projects/#{project.id}/w/#{job.workflow_id}?s=#{job.id}&v=#{workflow.lock_version}"
        )

      view |> CredentialLiveHelpers.select_credential_type("raw")
      view |> CredentialLiveHelpers.click_continue()

      view
      |> form("#credential-form-new",
        credential: %{
          name: "newly created credential",
          body: Jason.encode!(%{"a" => 1})
        }
      )
      |> render_submit()

      refute has_element?(view, "#credential-form")

      assert view
             |> element(
               ~S{[name='workflow[jobs][0][project_credential_id]'] option[selected="selected"]}
             )
             |> render() =~ "newly created credential",
             "Should have the project credential selected"
    end
  end

  describe "new" do
    test "builds a new workflow", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/w/new")

      # Naively add a job via the editor (calling the push-change event)
      assert view
             |> push_patches_to_view([add_job_patch()])

      # The server responds with a patch with any further changes
      assert_reply(
        view,
        %{
          patches: [
            %{op: "add", path: "/jobs/0/project_credential_id", value: nil},
            %{
              op: "add",
              path: "/jobs/0/errors",
              value: %{
                "body" => ["Code editor cannot be empty."],
                "name" => ["Job name can't be blank."]
              }
            },
            %{op: "add", path: "/jobs/0/disabled", value: false},
            %{op: "add", path: "/jobs/0/body", value: ""},
            %{
              op: "add",
              path: "/jobs/0/adaptor",
              value: "@openfn/language-common@latest"
            },
            %{
              op: "add",
              path: "/errors/jobs",
              value: [
                %{
                  "body" => ["Code editor cannot be empty."],
                  "name" => ["Job name can't be blank."]
                }
              ]
            }
          ]
        }
      )
    end

    @tag role: :editor
    test "creating a new workflow", %{conn: conn, project: project} do
      Mox.verify_on_exit!()
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/w/new")

      assert view |> push_patches_to_view(initial_workflow_patchset(project))

      workflow_name = view |> get_workflow_params() |> Map.get("name")

      assert workflow_name == ""

      assert view |> element("#workflow_name_form") |> render() =~ workflow_name

      assert view |> save_is_disabled?()

      workflow_name = "My Workflow"
      view |> fill_workflow_name(workflow_name)

      assert view |> save_is_disabled?()

      {job, _, _} = view |> select_first_job()

      view |> fill_job_fields(job, %{name: "My Job"})

      refute view |> selected_adaptor_version_element(job) |> render() =~
               ~r(value="@openfn/[a-z-]+@latest"),
             "should not have @latest selected by default"

      view |> CredentialLiveHelpers.select_credential_type("dhis2")

      view |> CredentialLiveHelpers.click_continue()

      # Creating a new credential from the Job panel
      view
      |> CredentialLiveHelpers.fill_credential(%{
        name: "My Credential",
        body: %{username: "foo", password: "bar", hostUrl: "http://someurl"}
      })

      view |> CredentialLiveHelpers.click_save()

      assert view |> selected_credential(job) =~ "My Credential"

      # Editing the Jobs' body
      view |> click_edit(job)

      view |> change_editor_text("some body")

      refute view |> save_is_disabled?()

      assert view |> has_pending_changes()

      # Try saving with the limitter
      error_msg = "Oopsie Doopsie! An error occured"

      Mox.expect(
        Lightning.Extensions.MockUsageLimiter,
        :limit_action,
        1,
        fn %{type: :activate_workflow}, _context ->
          {:error, :too_many_workflows, %{text: error_msg}}
        end
      )

      html = click_save(view)

      assert html =~ error_msg

      # let return ok with the limitter
      Mox.expect(
        Lightning.Extensions.MockUsageLimiter,
        :limit_action,
        1,
        fn %{type: :activate_workflow}, _context ->
          :ok
        end
      )

      # subscribe to workflow events
      Lightning.Workflows.subscribe(project.id)

      click_save(view)

      assert %{id: workflow_id} =
               workflow =
               Lightning.Repo.one(
                 from w in Workflow,
                   where:
                     w.project_id == ^project.id and
                       w.name ==
                         ^workflow_name
               )

      assert_patched(
        view,
        ~p"/projects/#{project.id}/w/#{workflow_id}?#{[m: "expand", s: job.id, v: workflow.lock_version]}"
      )

      render(view) =~ "Workflow saved"

      # workflow updated event is emitted
      assert_received %Lightning.Workflows.Events.WorkflowUpdated{
        workflow: %{id: ^workflow_id}
      }
    end

    @tag role: :viewer
    test "viewers can't create new workflows", %{conn: conn, project: project} do
      {:ok, _view, html} =
        live(conn, ~p"/projects/#{project.id}/w/new")
        |> follow_redirect(conn, ~p"/projects/#{project.id}/w")

      assert html =~ "You are not authorized to perform this action."
    end
  end

  describe "edit" do
    setup :create_workflow

    test "Switching between workflow versions maintains correct read-only and edit modes",
         %{conn: conn, project: project, workflow: workflow} do
      {:ok, view, _html} =
        live(
          conn,
          ~p"/projects/#{project.id}/w/#{workflow.id}?#{[v: workflow.lock_version]}"
        )

      {:ok, snapshot} = Snapshot.get_or_create_latest_for(workflow)

      assert snapshot.lock_version == workflow.lock_version

      assert view
             |> has_element?(
               "[id='canvas-workflow-version'][aria-label='This is the latest version of this workflow']",
               "latest"
             )

      refute view
             |> has_element?(
               "[id='version-switcher-canvas-#{workflow.id}][data-version='latest']"
             )

      view |> fill_workflow_name("#{workflow.name} v2")

      workflow.jobs
      |> Enum.with_index()
      |> Enum.each(fn {job, idx} ->
        view |> select_node(job, workflow.lock_version)

        refute view
               |> has_element?("[id='workflow_jobs_#{idx}_name'][disabled]")

        refute view |> has_element?("[id='adaptor-name'][disabled]")
        refute view |> has_element?("[id='adaptor-version'][disabled]")

        refute view
               |> has_element?(
                 "[id='workflow_jobs_#{idx}_project_credential_id'][disabled]"
               )

        view |> click_edit(job)

        assert view
               |> has_element?(
                 "[id='inspector-workflow-version'][aria-label='This is the latest version of this workflow']",
                 "latest"
               )

        refute view
               |> has_element?("[id='manual_run_form_dataclip_id'][disabled]")

        refute view
               |> has_element?(
                 "[id='job-editor-#{job.id}'][data-disabled='true'][data-disabled-message='Cannot edit in snapshot mode, switch to the latest version.']"
               )

        refute view
               |> has_element?("[id='version-switcher-inspector-#{job.id}]")

        refute view
               |> has_element?(
                 "[type='submit'][form='workflow-form'][disabled]",
                 "Save"
               )
      end)

      workflow.edges
      |> Enum.with_index()
      |> Enum.each(fn {edge, idx} ->
        view |> select_node(edge, workflow.lock_version)

        refute view
               |> has_element?(
                 "[id='workflow_edges_#{idx}_condition_type'][disabled]"
               )
      end)

      workflow.triggers
      |> Enum.with_index()
      |> Enum.each(fn {trigger, idx} ->
        view |> select_node(trigger, workflow.lock_version)

        refute view
               |> has_element?("[id='triggerType'][disabled]")

        refute view
               |> has_element?(
                 "[id='workflow_triggers_#{idx}_enabled'][disabled]"
               )
      end)

      job_1 = List.first(workflow.jobs)

      view |> select_node(job_1, workflow.lock_version)

      view
      |> form("#workflow-form", %{
        "workflow" => %{
          "jobs" => %{
            "0" => %{
              "name" => "#{job_1.name} v2"
            }
          }
        }
      })
      |> render_change()

      view
      |> form("#workflow-form")
      |> render_submit()

      workflow = Repo.reload!(workflow)

      assert snapshot.lock_version < workflow.lock_version

      version = String.slice(snapshot.id, 0..6)

      {:ok, view, _html} =
        live(
          conn,
          ~p"/projects/#{project.id}/w/#{workflow.id}?#{[v: snapshot.lock_version]}"
        )

      assert view
             |> has_element?(
               "[id='canvas-workflow-version'][aria-label='You are viewing a snapshot of this workflow that was taken on #{Helpers.format_date(snapshot.inserted_at)}']",
               version
             )

      assert view
             |> has_element?(
               "[id='version-switcher-button-#{workflow.id}']",
               "Switch to latest version"
             )

      snapshot.jobs
      |> Enum.with_index()
      |> Enum.each(fn {job, idx} ->
        view |> select_node(job, workflow.lock_version)

        assert view
               |> has_element?("[id='snapshot_jobs_#{idx}_name'][disabled]")

        assert view |> has_element?("[id='adaptor-name'][disabled]")
        assert view |> has_element?("[id='adaptor-version'][disabled]")

        assert view
               |> has_element?(
                 "[id='snapshot_jobs_#{idx}_project_credential_id'][disabled]"
               )

        view |> click_edit(job)

        assert view
               |> has_element?(
                 "[id='inspector-workflow-version'][aria-label='You are viewing a snapshot of this workflow that was taken on #{Helpers.format_date(snapshot.inserted_at)}']",
                 version
               )

        assert view
               |> has_element?("[id='manual_run_form_dataclip_id'][disabled]")

        assert view
               |> has_element?(
                 "[id='job-editor-#{job.id}'][data-disabled='true'][data-disabled-message='Cannot edit in snapshot mode, switch to the latest version.']"
               )

        assert view
               |> has_element?("[id='version-switcher-toggle-#{job.id}]")

        assert view
               |> has_element?(
                 "[type='submit'][form='workflow-form'][disabled]",
                 "Save"
               )
      end)

      snapshot.edges
      |> Enum.with_index()
      |> Enum.each(fn {edge, idx} ->
        view |> select_node(edge, workflow.lock_version)

        assert view
               |> has_element?(
                 "[id='snapshot_edges_#{idx}_condition_type'][disabled]"
               )
      end)

      snapshot.triggers
      |> Enum.with_index()
      |> Enum.each(fn {trigger, idx} ->
        view |> select_node(trigger, workflow.lock_version)

        assert view
               |> has_element?("[id='triggerType'][disabled]")

        assert view
               |> has_element?(
                 "[id='snapshot_triggers_#{idx}_enabled'][disabled]"
               )
      end)

      last_job = List.last(snapshot.jobs)
      last_edge = List.last(snapshot.edges)

      force_event(view, :save) =~
        "Cannot save in snapshot mode, switch to the latest version."

      force_event(view, :delete_node, last_job) =~
        "Cannot delete a node in snapshot mode, switch to latest"

      force_event(view, :delete_edge, last_edge) =~
        "Cannot delete a node in snapshot mode, switch to latest"

      force_event(view, :manual_run_submit, %{}) =~
        "Cannot run in snapshot mode, switch to latest."

      force_event(view, :rerun, nil, nil) =~
        "Cannot rerun in snapshot mode, switch to latest."

      assert view
             |> element(
               "p",
               "You cannot edit or run an old snapshot of a workflow."
             )
             |> has_element?()

      assert view
             |> element("#version-switcher-button-#{workflow.id}")
             |> has_element?()

      refute view |> element("[type='submit']", "Save") |> has_element?()

      view
      |> element("#version-switcher-button-#{workflow.id}")
      |> render_click()

      refute view
             |> element(
               "p",
               "You cannot edit or run an old snapshot of a workflow."
             )
             |> has_element?()

      refute view
             |> element("#version-switcher-button-#{workflow.id}")
             |> has_element?()

      assert view |> element("[type='submit']", "Save") |> has_element?()
    end

    test "Inspector renders run thru their snapshots and allows switching to the latest versions for edition",
         %{conn: conn, project: project, workflow: workflow} do
      {:ok, earliest_snapshot} = Snapshot.get_or_create_latest_for(workflow)

      run_1 =
        insert(:run,
          work_order: build(:workorder, workflow: workflow),
          starting_trigger: build(:trigger),
          dataclip: build(:dataclip),
          finished_at: build(:timestamp),
          snapshot: earliest_snapshot,
          state: :started
        )

      jobs_attrs =
        workflow.jobs
        |> Enum.with_index()
        |> Enum.map(fn {job, idx} ->
          %{
            id: job.id,
            name: "job-number-#{idx}",
            body:
              ~s[fn(state => { console.log("job body number #{idx}"); return state; })]
          }
        end)

      {:ok, workflow} =
        Workflows.change_workflow(workflow, %{jobs: jobs_attrs})
        |> Workflows.save_workflow()

      {:ok, latest_snapshot} = Snapshot.get_or_create_latest_for(workflow)

      run_2 =
        insert(:run,
          work_order: build(:workorder, workflow: workflow),
          starting_trigger: build(:trigger),
          dataclip: build(:dataclip),
          finished_at: build(:timestamp),
          snapshot: latest_snapshot,
          state: :started
        )

      job_1 = List.last(run_1.snapshot.jobs)

      {:ok, view, _html} =
        live(
          conn,
          ~p"/projects/#{project}/w/#{workflow}?#{[a: run_1, s: job_1, m: "expand", v: run_1.snapshot.lock_version]}"
        )

      run_1_version = String.slice(run_1.snapshot.id, 0..6)

      assert view
             |> has_element?(
               "[id='inspector-workflow-version'][aria-label='You are viewing a snapshot of this workflow that was taken on #{Helpers.format_date(run_1.snapshot.inserted_at)}']",
               run_1_version
             )

      assert view
             |> has_element?(
               "#job-editor-panel-panel-header-title",
               "Editor (read-only)"
             )

      assert view
             |> has_element?(
               "[id='job-editor-#{job_1.id}'][data-disabled-message='Cannot edit in snapshot mode, switch to the latest version.'][data-disabled='true'][data-source='#{job_1.body}']"
             )

      assert view |> has_element?("[id='manual_run_form_dataclip_id'][disabled]")

      assert view |> has_element?("div", job_1.name)

      view |> element("#version-switcher-toggle-#{job_1.id}") |> render_click()

      job_2 = List.last(run_2.snapshot.jobs)

      assert view
             |> has_element?(
               "[id='inspector-workflow-version'][aria-label='This is the latest version of this workflow']",
               "latest"
             )

      assert view
             |> has_element?(
               "#job-editor-panel-panel-header-title",
               "Editor"
             )

      assert view
             |> has_element?(
               "[id='job-editor-#{job_1.id}'][data-disabled-message=''][data-disabled='false'][data-source='#{job_2.body}']"
             )

      refute view |> has_element?("[id='manual_run_form_dataclip_id'][disabled]")

      assert view |> has_element?("div", job_2.name)
    end

    test "Can't switch to the latest version from a deleted step", %{
      conn: conn,
      project: project,
      workflow: workflow
    } do
      {:ok, snapshot} = Snapshot.get_or_create_latest_for(workflow)

      run =
        insert(:run,
          work_order: build(:workorder, workflow: workflow),
          starting_trigger: build(:trigger),
          dataclip: build(:dataclip),
          finished_at: build(:timestamp),
          snapshot: snapshot,
          state: :started
        )

      jobs_attrs =
        workflow.jobs
        |> Enum.with_index()
        |> Enum.map(fn {job, idx} ->
          %{
            id: job.id,
            name: "job-number-#{idx}",
            body:
              ~s[fn(state => { console.log("job body number #{idx}"); return state; })]
          }
        end)

      {:ok, workflow} =
        Workflows.change_workflow(workflow, %{jobs: jobs_attrs})
        |> Workflows.save_workflow()

      {:ok, latest_snapshot} = Snapshot.get_or_create_latest_for(workflow)

      insert(:run,
        work_order: build(:workorder, workflow: workflow),
        starting_trigger: build(:trigger),
        dataclip: build(:dataclip),
        finished_at: build(:timestamp),
        snapshot: latest_snapshot,
        state: :started
      )

      job_to_delete = workflow.jobs |> List.last() |> Repo.delete!()

      workflow = Repo.reload(workflow) |> Repo.preload(:jobs)

      {:ok, view, _html} =
        live(
          conn,
          ~p"/projects/#{project}/w/#{workflow}?#{[a: run, s: job_to_delete, m: "expand", v: run.snapshot.lock_version]}"
        )

      assert view
             |> has_element?(
               "[id='version-switcher-toggle-#{job_to_delete.id}'][disabled]"
             )

      assert view
             |> render_click("switch-version", %{"type" => "toggle"}) =~
               "Can&#39;t switch to the latest version, the job has been deleted from the workflow."
    end

    test "click on pencil icon activates workflow name edit mode", %{
      conn: conn,
      project: project,
      workflow: workflow
    } do
      another_workflow =
        workflow_fixture(name: "A random workflow", project_id: project.id)

      {:ok, view, _html} =
        live(
          conn,
          ~p"/projects/#{project.id}/w/#{workflow.id}?#{[v: workflow.lock_version]}"
        )

      assert view |> has_element?(~s(input[name="workflow[name]"]))

      assert view
             |> form("#workflow_name_form", %{"workflow" => %{"name" => ""}})
             |> render_change() =~ "can&#39;t be blank"

      html =
        view
        |> form("#workflow_name_form", %{
          "workflow" => %{"name" => another_workflow.name}
        })
        |> render_submit()

      assert html =~ "a workflow with this name already exists in this project."
      assert html =~ "Workflow could not be saved"

      assert view
             |> form("#workflow_name_form", %{
               "workflow" => %{"name" => "some new name"}
             })
             |> render_submit() =~ "Workflow saved"
    end

    test "renders error message when a job has an empty body", %{
      conn: conn,
      project: project,
      workflow: workflow
    } do
      {:ok, view, _html} =
        live(
          conn,
          ~p"/projects/#{project.id}/w/#{workflow.id}?#{[v: workflow.lock_version]}"
        )

      job = workflow.jobs |> Enum.at(1)

      view |> select_node(job, workflow.lock_version)

      view |> click_edit(job)

      view |> change_editor_text("some body")

      refute view |> render() =~
               "Code editor cannot be empty."

      view |> change_editor_text("")

      assert view |> render() =~
               "Code editor cannot be empty."
    end

    test "allows editing job name", %{
      conn: conn,
      project: project,
      workflow: workflow
    } do
      {:ok, view, _html} =
        live(
          conn,
          ~p"/projects/#{project.id}/w/#{workflow.id}?#{[v: workflow.lock_version]}"
        )

      assert view |> page_title() =~ workflow.name

      view |> fill_workflow_name("")

      job_2 = workflow.jobs |> Enum.at(1)

      view |> select_node(job_2, workflow.lock_version)
      view |> fill_job_fields(job_2, %{name: ""})

      assert view |> job_form_has_error(job_2, "name", "can't be blank")
      assert view |> save_is_disabled?()

      new_job_name = "My Other Job"

      assert view |> fill_job_fields(job_2, %{name: new_job_name}) =~
               new_job_name

      assert view |> save_is_disabled?()
    end

    test "opens edge Path form and saves the JS expression", %{
      conn: conn,
      project: project,
      workflow: workflow
    } do
      {:ok, view, _html} =
        live(
          conn,
          ~p"/projects/#{project.id}/w/#{workflow.id}?#{[v: workflow.lock_version]}"
        )

      form_html =
        view |> select_node(Enum.at(workflow.jobs, 0), workflow.lock_version)

      assert form_html =~ "Job Name"
      refute form_html =~ "Path"

      form_html =
        view |> select_node(Enum.at(workflow.edges, 0), workflow.lock_version)

      assert form_html =~ "Path"

      assert form_html =~
               ~S[<option selected="selected" value="always">Always</option><option value="js_expression">Matches a Javascript Expression</option></select>]

      edge_on_edit = Enum.at(workflow.edges, 1)
      form_html = view |> select_node(edge_on_edit, workflow.lock_version)

      assert form_html =~
               ~S[<option selected="selected" value="on_job_success">On Success</option>]

      refute form_html =~ "Condition Label"

      form_html =
        view
        |> form("#workflow-form", %{
          "workflow" => %{
            "edges" => %{"1" => %{"condition_type" => "js_expression"}}
          }
        })
        |> render_change()

      assert form_html =~ "Condition Label"

      assert form_html =~
               ~S[<option selected="selected" value="js_expression">Matches a Javascript Expression</option>]

      view
      |> form("#workflow-form", %{
        "workflow" => %{
          "edges" => %{
            "1" => %{
              "condition_label" => "My JS Expression",
              "condition_expression" => "state.data.field === 33"
            }
          }
        }
      })
      |> render_change()

      view
      |> form("#workflow-form")
      |> render_submit()

      assert Map.delete(Repo.reload!(edge_on_edit), :updated_at) ==
               Map.delete(
                 Map.merge(edge_on_edit, %{
                   condition_type: :js_expression,
                   condition_label: "My JS Expression",
                   condition_expression: "state.data.field === 33"
                 }),
                 :updated_at
               )
    end

    @tag role: :editor
    test "can delete a job", %{conn: conn, project: project, workflow: workflow} do
      {:ok, view, _html} =
        live(
          conn,
          ~p"/projects/#{project}/w/#{workflow}?#{[v: workflow.lock_version]}"
        )

      [job_1, job_2] = workflow.jobs
      view |> select_node(job_1, workflow.lock_version)

      assert view |> delete_job_button_is_disabled?(job_1)

      # Test that the delete event doesn't work even if the button is disabled.
      assert view |> force_event(:delete_node, job_1) =~
               "Delete all descendant steps first."

      view |> select_node(job_2, workflow.lock_version)

      assert_patched(
        view,
        ~p"/projects/#{project}/w/#{workflow}?s=#{job_2}&v=#{workflow.lock_version}"
      )

      refute view |> delete_job_button_is_disabled?(job_2)

      view |> click_delete_job(job_2)

      assert_push_event(view, "patches-applied", %{
        patches: [
          %{op: "remove", path: "/jobs/1"},
          %{op: "remove", path: "/edges/1"}
        ]
      })
    end

    @tag role: :editor
    test "cannot delete an edge between a trigger and a job", %{
      conn: conn,
      project: project,
      workflow: workflow
    } do
      {:ok, view, _html} =
        live(
          conn,
          ~p"/projects/#{project}/w/#{workflow}?#{[v: workflow.lock_version]}"
        )

      [trigger_edge, other_edge] = workflow.edges

      assert view |> select_node(other_edge, workflow.lock_version) =~
               "Delete Path"

      refute view |> select_node(trigger_edge, workflow.lock_version) =~
               "Delete Path"

      assert view |> force_event(:delete_edge, trigger_edge) =~
               "You cannot remove the first edge in a workflow."
    end

    @tag role: :editor
    test "can delete an edge between two jobs", %{
      conn: conn,
      project: project,
      workflow: workflow
    } do
      {:ok, view, _html} =
        live(
          conn,
          ~p"/projects/#{project}/w/#{workflow}?#{[v: workflow.lock_version]}"
        )

      [_trigger_edge, other_edge] = workflow.edges

      assert view |> select_node(other_edge, workflow.lock_version) =~
               "Delete Path"

      view |> select_node(other_edge, workflow.lock_version)

      assert_patched(
        view,
        ~p"/projects/#{project}/w/#{workflow}?s=#{other_edge}&v=#{workflow.lock_version}"
      )

      view |> click_delete_edge(other_edge)

      assert_push_event(view, "patches-applied", %{
        patches: [
          %{op: "remove", path: "/edges/1"}
        ]
      })
    end

    @tag role: :viewer
    test "cannot delete edges", %{
      conn: conn,
      project: project,
      workflow: workflow
    } do
      {:ok, view, _html} =
        live(
          conn,
          ~p"/projects/#{project}/w/#{workflow}?#{[v: workflow.lock_version]}"
        )

      [_trigger_edge, other_edge] = workflow.edges

      assert view |> select_node(other_edge, workflow.lock_version) =~
               "Delete Path"

      view |> select_node(other_edge, workflow.lock_version)

      assert_patched(
        view,
        ~p"/projects/#{project}/w/#{workflow}?s=#{other_edge}&v=#{workflow.lock_version}"
      )

      assert view |> delete_edge_button_is_disabled?(other_edge)

      assert view |> force_event(:delete_edge, other_edge) =~
               "You are not authorized to delete edges."
    end

    @tag role: :editor
    test "can't delete the first step in a workflow", %{
      conn: conn,
      project: project
    } do
      trigger = build(:trigger, type: :webhook)

      job =
        build(:job,
          body: ~s[fn(state => { return {...state, extra: "data"} })],
          name: "First Job"
        )

      workflow =
        build(:workflow, project: project)
        |> with_job(job)
        |> with_trigger(trigger)
        |> with_edge({trigger, job})
        |> insert()

      {:ok, _snapshot} = Workflows.Snapshot.get_or_create_latest_for(workflow)

      {:ok, view, _html} =
        live(
          conn,
          ~p"/projects/#{project}/w/#{workflow}?#{[v: workflow.lock_version]}"
        )

      view |> select_node(job, workflow.lock_version)

      assert view |> delete_job_button_is_disabled?(job)

      assert view |> force_event(:delete_node, job) =~
               "You can&#39;t delete the first step in a workflow."
    end

    @tag role: :editor
    test "can delete a step that has already been ran", %{
      conn: conn,
      project: project
    } do
      trigger = build(:trigger, type: :webhook)

      [job_a, job_b] = insert_list(2, :job)

      workflow =
        build(:workflow)
        |> with_job(job_a)
        |> with_job(job_b)
        |> with_trigger(trigger)
        |> with_edge({trigger, job_a})
        |> with_edge({job_a, job_b})
        |> insert()

      insert(:step, job: job_b)

      {:ok, _snapshot} = Workflows.Snapshot.get_or_create_latest_for(workflow)

      {:ok, view, _html} =
        live(
          conn,
          ~p"/projects/#{project}/w/#{workflow}?#{[v: workflow.lock_version]}"
        )

      view |> select_node(job_b, workflow.lock_version)

      assert_patched(
        view,
        ~p"/projects/#{project}/w/#{workflow}?s=#{job_b}&v=#{workflow.lock_version}"
      )

      refute view |> delete_job_button_is_disabled?(job_b)

      view |> click_delete_job(job_b)

      project_id = project.id

      assert_push_event(view, "patches-applied", %{
        patches: [
          %{value: ^project_id, path: "/project_id", op: "replace"},
          %{op: "remove", path: "/jobs/1"},
          %{op: "remove", path: "/edges/1"}
        ]
      })
    end

    @tag role: :editor
    test "can't delete any job that has downstream jobs",
         %{
           conn: conn,
           project: project
         } do
      trigger = build(:trigger, type: :webhook)

      [job_a, job_b, job_c] = build_list(3, :job)

      workflow =
        build(:workflow)
        |> with_job(job_a)
        |> with_job(job_b)
        |> with_job(job_c)
        |> with_trigger(trigger)
        |> with_edge({trigger, job_a})
        |> with_edge({job_a, job_b})
        |> with_edge({job_b, job_c})
        |> insert()

      {:ok, _snapshot} = Workflows.Snapshot.get_or_create_latest_for(workflow)

      {:ok, view, html} =
        live(
          conn,
          ~p"/projects/#{project}/w/#{workflow}?s=#{job_a}&v=#{workflow.lock_version}"
        )

      assert view |> delete_job_button_is_disabled?(job_a)

      assert html =~
               "You can&#39;t delete a step that other downstream steps depend on"

      assert view |> force_event(:delete_node, job_a) =~
               "Delete all descendant steps first"

      {:ok, view, html} =
        live(
          conn,
          ~p"/projects/#{project}/w/#{workflow}?s=#{job_b}&v=#{workflow.lock_version}"
        )

      assert view |> delete_job_button_is_disabled?(job_b)

      assert html =~
               "You can&#39;t delete a step that other downstream steps depend on"

      assert view |> force_event(:delete_node, job_a) =~
               "Delete all descendant steps first"
    end

    @tag role: :viewer
    test "viewers can't edit existing jobs", %{
      conn: conn,
      project: project,
      workflow: workflow
    } do
      {:ok, view, _html} =
        live(
          conn,
          ~p"/projects/#{project.id}/w/#{workflow.id}?#{[v: workflow.lock_version]}"
        )

      view |> select_node(workflow.triggers |> Enum.at(0), workflow.lock_version)

      assert view |> input_is_disabled?("[name='workflow[triggers][0][type]']")

      view |> select_node(workflow.edges |> Enum.at(0), workflow.lock_version)

      assert view
             |> input_is_disabled?("[name='workflow[edges][0][condition_type]']")

      assert view |> save_is_disabled?()
      job_1 = workflow.jobs |> Enum.at(0)

      view |> select_node(job_1, workflow.lock_version)

      assert view |> input_is_disabled?(job_1, "name")

      assert view |> input_is_disabled?("[name='adaptor_picker[adaptor_name]']")
      assert view |> input_is_disabled?(job_1, "adaptor")
      assert view |> input_is_disabled?(job_1, "project_credential_id")

      assert view |> delete_job_button_is_disabled?(job_1)

      # Test that the delete event doesn't work even if the button is disabled.
      assert view |> force_event(:delete_node, job_1) =~
               "You are not authorized to perform this action."

      assert view |> save_is_disabled?()

      view |> click_close_error_flash()

      assert view |> force_event(:save) =~
               "You are not authorized to perform this action."

      view |> click_close_error_flash()

      assert view |> force_event(:form_changed) =~
               "You are not authorized to perform this action."

      view |> click_close_error_flash()

      assert view |> force_event(:validate) =~
               "You are not authorized to perform this action."
    end

    test "can enable/disable any edge between two jobs", %{
      conn: conn,
      project: project,
      workflow: workflow
    } do
      edge =
        Enum.find(workflow.edges, fn edge -> edge.source_job_id != nil end)

      assert edge.enabled

      {:ok, view, html} =
        live(
          conn,
          ~p"/projects/#{project.id}/w/#{workflow.id}?s=#{edge.id}&v=#{workflow.lock_version}"
        )

      idx = get_index_of_edge(view, edge)

      assert html =~ "Disable this path"

      assert view
             |> element("#workflow_edges_#{idx}_enabled")
             |> has_element?()

      view
      |> form("#workflow-form", %{
        "workflow" => %{"edges" => %{to_string(idx) => %{"enabled" => false}}}
      })
      |> render_change()

      view
      |> form("#workflow-form")
      |> render_submit()

      edge = Repo.reload!(edge)

      refute edge.enabled

      assert view
             |> element("#workflow_edges_#{idx}_enabled[checked]")
             |> has_element?()
    end

    test "does not call the limiter when the trigger is not enabled", %{
      conn: conn,
      project: project,
      workflow: workflow
    } do
      Mox.verify_on_exit!()

      {:ok, view, _html} =
        live(
          conn,
          ~p"/projects/#{project.id}/w/#{workflow.id}?#{[v: workflow.lock_version]}"
        )

      # We expect zero calls
      Mox.expect(
        Lightning.Extensions.MockUsageLimiter,
        :limit_action,
        0,
        fn %{type: :activate_workflow}, _context ->
          {:error, :too_many_workflows, %{text: "some error message"}}
        end
      )

      job_2 = workflow.jobs |> Enum.at(1)

      view |> select_node(job_2, workflow.lock_version)

      new_job_name = "My Other Job"

      assert view |> fill_job_fields(job_2, %{name: new_job_name}) =~
               new_job_name

      click_save(view)

      assert Lightning.Repo.reload(job_2).name == new_job_name
    end

    test "calls the limiter when the trigger is enabled", %{
      conn: conn,
      project: project,
      workflow: workflow
    } do
      Mox.verify_on_exit!()

      workflow.triggers
      |> hd()
      |> Ecto.Changeset.change(%{enabled: false})
      |> Lightning.Repo.update!()

      {:ok, view, _html} =
        live(
          conn,
          ~p"/projects/#{project.id}/w/#{workflow.id}?#{[v: workflow.lock_version]}"
        )

      # We expect 1 call
      error_msg = "Oopsie Doopsie! An error occured"

      Mox.expect(
        Lightning.Extensions.MockUsageLimiter,
        :limit_action,
        1,
        fn %{type: :activate_workflow}, _context ->
          {:error, :too_many_workflows, %{text: error_msg}}
        end
      )

      select_trigger(view)

      view
      |> form("#workflow-form", %{
        "workflow" => %{"triggers" => %{"0" => %{"enabled" => true}}}
      })
      |> render_change()

      html = click_save(view)

      assert html =~ error_msg
    end
  end
end
