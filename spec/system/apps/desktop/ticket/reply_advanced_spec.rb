# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

RSpec.describe 'Desktop > Ticket > Editor and Advanced Features', app: :desktop_view, authenticated_as: :agent1, type: :system do
  let(:agent1)    { create(:agent, groups: [group]) }
  let(:agent2)    { create(:agent, groups: [group]) }
  let(:signature) { create(:signature) }
  let(:group)     { create(:group, signature:) }
  let(:customer)  { create(:customer) }

  let(:first_cite)  { 'First selectable customer text to cite.' }
  let(:second_cite) { 'Second selectable customer text to cite.' }

  let(:article_body) do
    [
      "<p>#{first_cite}</p>",
      "<p>#{second_cite}</p>",
    ].join
  end

  let(:article) do
    create(:ticket_article, :inbound_email,
           ticket: ticket, body: article_body, content_type: 'text/html', from: customer.email)
  end

  let(:ticket) { create(:ticket, group:, customer:, title: 'Editor scenario test') }

  let(:support_type)    { create(:ticket_time_accounting_type, name: 'Support') }
  let(:consulting_type) { create(:ticket_time_accounting_type, name: 'Consulting') }

  let(:text_module) do
    create(:text_module,
           name:     'greet-customer',
           keywords: 'greet',
           content:  'Hello #{ticket.customer.firstname},') # rubocop:disable Lint/InterpolationCheck
  end

  before do
    Setting.set('time_accounting', true)
    Setting.set('time_accounting_types', true)
    Setting.set('time_accounting_unit', 'minute')

    # Activating full quote makes the editor add the signature for inline
    # quotes as a side effect, which positions the cursor correctly above the
    # quoted block instead of inside it.
    Setting.set('ui_ticket_zoom_article_email_full_quote', true)

    support_type
    consulting_type
    text_module
    agent2
    article

    visit "/tickets/#{ticket.id}"
    wait_for_form_to_settle("form-ticket-edit-#{ticket.id}")
  end

  it 'covers the full editor and advanced features scenario', performs_jobs: true do
    cite_article_text(first_cite)
    find_editor('Text').input_element.send_keys(' First reply text.')

    cite_article_text(second_cite)
    find_editor('Text').input_element.send_keys(' Second reply text.')

    # TODO: Re-add toolbar-visible-while-scrolling assertion once the sticky
    # toolbar layout bug (toolbar hidden behind page header on scroll) is fixed.

    insert_text_module_at_top

    apply_heading_to_current_block('Heading 1')

    add_h2_below_top_heading('Customer wrote')

    add_h2_before_second_cite('Customer continued')

    insert_table_at_end_of_draft
    select_table_option('Toggle header row')
    select_table_option('Toggle header column')
    fill_first_table_cell('A1')
    insert_row_between_existing_rows

    add_tag('editor-scenario')

    click_on 'Update'

    account_time(type: 'Support', minutes: '15')

    add_internal_note_with_mention(agent2)

    perform_enqueued_jobs

    expect_subscriber_avatar(agent2)
  end

  def cursor_home_shortcut
    mac_platform? ? %i[command up] : %i[control home]
  end

  def cursor_end_shortcut
    mac_platform? ? %i[command down] : %i[control end]
  end

  def cite_article_text(text)
    page.execute_script(<<~JS)
      var root = document.querySelector('#article-#{article.id} .inner-article-body');
      var paragraph = Array.from(root.querySelectorAll('p')).find(function (node) {
        return node.textContent === #{text.to_json};
      });
      var range = document.createRange();
      range.selectNodeContents(paragraph);
      var selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
    JS

    within "#article-#{article.id}" do
      find('button', exact_text: 'Reply', visible: :all).click
    end

    expect(page).to have_css('blockquote', text: text)
  end

  def reply_form
    find('#ticketArticleReplyForm')
  end

  # Click an editor toolbar action by its accessible label, falling back to the
  # "Overflow menu" popover when the toolbar wraps and the action is not
  # rendered directly. The popover items appear in the body, outside the form.
  def click_editor_toolbar_action(label)
    selector = %(button[aria-label="#{label}"])
    in_toolbar = false
    within(reply_form) do
      if has_css?(selector, wait: 0.5)
        in_toolbar = true
        find(selector).click
      else
        find('button[aria-label="Overflow menu"]').click
      end
    end
    return if in_toolbar

    find('[data-test-id="popover-menu-item"]', exact_text: label).click
  end

  def insert_text_module_at_top
    editor = find_editor('Text').input_element
    editor.click.send_keys(cursor_home_shortcut)

    click_editor_toolbar_action('Insert text from text module')

    within '[data-test-id="mention-text"]' do
      find('li[role="option"]', text: text_module.name).click
    end

    within(reply_form) do
      expect(page).to have_text("Hello #{customer.firstname},")
    end
  end

  def apply_heading_to_current_block(level_label)
    click_editor_toolbar_action('Add heading')

    find('[data-test-id="popover-menu-item"]', exact_text: level_label).click

    expected_tag = level_label == 'Heading 1' ? 'h1' : 'h2'
    within(reply_form) do
      expect(page).to have_css(expected_tag)
    end
  end

  # Place cursor at end of the top heading line and press Enter to create a new
  # block between the heading and the first cited blockquote, then format that
  # new block as H2.
  def add_h2_below_top_heading(text)
    editor = find_editor('Text').input_element
    editor.click.send_keys(cursor_home_shortcut, :end, :enter)

    apply_heading_to_current_block('Heading 2')

    editor.send_keys(text)
  end

  # Position the caret at the end of the "First reply text." paragraph (the
  # block immediately above the second cited blockquote), press Enter to insert
  # a new block between it and the second blockquote, then format as H2.
  def add_h2_before_second_cite(text)
    editor = find_editor('Text').input_element

    page.execute_script(<<~JS)
      var box = document.querySelector('#ticketArticleReplyForm [role="textbox"]');
      var paragraph = Array.from(box.querySelectorAll('p')).find(function (node) {
        return node.textContent.trim() === 'First reply text.';
      });
      var range = document.createRange();
      range.selectNodeContents(paragraph);
      range.collapse(false);
      var selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
    JS

    editor.send_keys(:enter)

    apply_heading_to_current_block('Heading 2')

    editor.send_keys(text)
  end

  def insert_table_at_end_of_draft
    editor = find_editor('Text').input_element
    editor.click.send_keys(cursor_end_shortcut)

    click_editor_toolbar_action('Insert table')

    within(reply_form) do
      expect(page).to have_table
      # The Insert table action chains an empty <p> at the end of the document
      # which leaves the caret outside the table. Click into the first cell so
      # the contextual "Table options" button becomes available.
      first('table tr:first-child td, table tr:first-child th').click
    end
  end

  def select_table_option(label)
    # The "Table options" button is a separate floating control (absolutely
    # positioned next to the table) rather than a toolbar action.
    find('button[aria-label="Table options"]').click

    find('[data-test-id="popover-menu-item"]', exact_text: label).click
  end

  def fill_first_table_cell(content)
    within(reply_form) do
      cell = first('table tr:first-child td, table tr:first-child th')
      cell.click
      cell.send_keys(content)
    end
  end

  def insert_row_between_existing_rows
    within(reply_form) do
      # Cursor in a cell of the first row → "Insert row below" creates a row
      # between the first and second existing rows.
      first('table tr:first-child td, table tr:first-child th').click
    end

    select_table_option('Insert row below')

    within(reply_form) do
      expect(page).to have_css('table tr', count: 4)
    end
  end

  def add_tag(tag)
    click_on 'Add tag'

    find_autocomplete('Add tag').open.input_element.fill_in(with: tag).send_keys(:tab)

    wait_for_gql('shared/entities/tags/graphql/mutations/assignment/add.graphql', number: 1)

    expect(page).to have_text('Ticket tag added successfully')
    expect(ticket.reload.tag_list).to include(tag)
  end

  def account_time(type:, minutes:)
    within '#flyout-ticket-time-accounting' do
      expect(page).to have_text('Time accounting')

      find_select('Activity type').select_option(type)
      find_input('Accounted time').type(minutes)

      click_on 'Account time'
    end

    expect(page).to have_text('Ticket updated successfully.')

    expect(ticket.reload.articles.last.preferences['time_accounting']).to be_truthy
  end

  def add_internal_note_with_mention(agent)
    click_on 'Add internal note'

    expect(reply_form).to have_button('Mention user')

    click_editor_toolbar_action('Mention user')

    find_editor('Text').input_element.send_keys(agent.firstname)

    within '[data-test-id="mention-user"]' do
      find('li[role="option"]', text: agent.fullname).click
    end

    expect(reply_form).to have_css('span[data-mention-user-id]', text: agent.fullname)

    click_on 'Update'

    expect(page).to have_text('Ticket updated successfully.')
  end

  def expect_subscriber_avatar(agent)
    section = find('#ticketSidebar', text: 'Subscribers')
    section.click if first('button')['aria-expanded'] == 'false'

    within '#ticketSidebar' do
      expect(page).to have_css(%(span[aria-label="Avatar (#{agent.fullname})"]))
    end

    expect(ticket.reload.mentions.map(&:user)).to include(agent)
  end
end
